import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:palette_generator/palette_generator.dart';

import 'package:ember_flutter/services/python_service.dart';
import 'package:ember_flutter/services/database_service.dart';
import 'package:ember_flutter/services/recommender_service.dart';
import 'package:ember_flutter/utils/result.dart';
import 'package:ember_flutter/blocs/audio/audio_event.dart';
import 'package:ember_flutter/blocs/audio/audio_state.dart';

class AudioBloc extends Bloc<AudioEvent, AudioState> {
  final AndroidEqualizer equalizer = AndroidEqualizer();
  late final AudioPlayer player;

  // ignore: deprecated_member_use
  ConcatenatingAudioSource _playlist = ConcatenatingAudioSource(children: []);
  bool _isPreloading = false;
  bool _isRecoveringError = false;
  bool _isHandlingCompletion = false;
  final Map<String, int> _trackRetryCounts = {};

  // Storage of stream subs
  StreamSubscription? _currentIndexSub;
  StreamSubscription? _playerStateSub;
  StreamSubscription<PlayerException>? _errorSub;
  StreamSubscription<AudioDevicesChangedEvent>? _devicesChangedSub;
  Timer? _resumeSaveTimer;

  AudioBloc() : super(const AudioState()) {
    // Instantiate AudioPlayer without attaching AndroidEqualizer in AudioPipeline;
    // enabling android.media.audiofx.Equalizer by default conflicts with Bluetooth
    // A2DP/LE Audio offload and HAL routing on many Android devices, muting earbuds.
    // Configure generous Android buffering so lock-screen network dips don't stall playback.
    player = AudioPlayer(
      audioLoadConfiguration: const AudioLoadConfiguration(
        androidLoadControl: AndroidLoadControl(
          minBufferDuration: Duration(seconds: 30),
          maxBufferDuration: Duration(seconds: 120),
          bufferForPlaybackDuration: Duration(milliseconds: 2500),
          bufferForPlaybackAfterRebufferDuration: Duration(seconds: 5),
        ),
      ),
    );

    _initAudioSession();
    _loadResumeState();

    _resumeSaveTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (player.playing && state.currentTrack != null) {
        DatabaseService.instance.saveResumeState(
            state.currentTrack!, player.position.inMilliseconds);
      }
    });

    on<AudioPlayQueue>(_onPlayQueue);
    on<AudioPause>((event, emit) {
      player.pause();
      if (state.currentTrack != null) {
        DatabaseService.instance.saveResumeState(
            state.currentTrack!, player.position.inMilliseconds);
      }
    });
    on<AudioResume>((event, emit) async {
      if (player.audioSource == null &&
          state.currentTrack != null &&
          state.queue.isEmpty) {
        add(AudioPlayQueue([state.currentTrack!], startIndex: 0));
      } else {
        final session = await AudioSession.instance;
        await session.setActive(true);
        await player.play();
      }
    });

    on<AudioSetResumeState>((event, emit) {
      emit(state.copyWith(
        currentTrack: event.track,
        resumePositionMs: event.positionMs,
      ));
    });

    on<AudioStop>((event, emit) => player.stop());
    on<AudioClear>((event, emit) {
      player.stop();
      emit(const AudioState());
    });
    on<AudioSeekToNext>((event, emit) => player.seekToNext());
    on<AudioSeekToPrevious>(_onSeekToPrevious);
    on<AudioJumpToQueueIndex>(_onJumpToQueueIndex);

    // Internal state updates from streams
    on<AudioPlayerStateChanged>((event, emit) {
      emit(state.copyWith(playerState: event.playerState));
      if (event.playerState.processingState == ProcessingState.completed) {
        _handlePlaybackCompleted();
      }
    });

    on<AudioCurrentIndexChanged>(_onCurrentIndexChanged);
    on<AudioDominantColorUpdated>((event, emit) {
      emit(state.copyWith(dominantColor: event.color));
    });

    on<AudioUpdateQueue>((event, emit) {
      emit(state.copyWith(queue: event.newQueue));
    });

    on<AudioPlayNext>(_onPlayNext);
    on<AudioAddToQueue>(_onAddToQueue);

    _currentIndexSub = player.currentIndexStream.listen((index) {
      add(AudioCurrentIndexChanged(index));
    });

    _playerStateSub = player.playerStateStream.listen((state) {
      add(AudioPlayerStateChanged(state));
    });

    _errorSub = player.errorStream.listen(_onPlayerError);
  }

  Future<void> _initAudioSession() async {
    try {
      final session = await AudioSession.instance;
      if (!session.isConfigured) {
        await session.configure(const AudioSessionConfiguration.music());
      }
      _devicesChangedSub =
          session.devicesChangedEventStream.listen((event) async {
        final hasAddedOutput = event.devicesAdded.any(
          (device) => device.isOutput,
        );
        if (hasAddedOutput && !isClosed && player.playing) {
          await session.setActive(true);
        }
      });
    } catch (e) {
      debugPrint("Error initializing AudioSession: $e");
    }
  }

  Future<void> _loadResumeState() async {
    final resumeState = await DatabaseService.instance.getResumeState();
    if (resumeState != null &&
        state.currentTrack == null &&
        state.queue.isEmpty) {
      final track = resumeState['track'] as Map<String, String>;
      final positionMs = resumeState['positionMs'] as int;
      add(AudioSetResumeState(track, positionMs));
      if (track['artworkUrl'] != null && track['artworkUrl']!.isNotEmpty) {
        _updatePalette(track['artworkUrl']!);
      }
    }
  }

  @override
  Future<void> close() {
    _currentIndexSub?.cancel();
    _playerStateSub?.cancel();
    _errorSub?.cancel();
    _devicesChangedSub?.cancel();
    _resumeSaveTimer?.cancel();
    if (state.currentTrack != null) {
      DatabaseService.instance
          .saveResumeState(state.currentTrack!, player.position.inMilliseconds);
    }
    player.dispose();
    return super.close();
  }

  Future<void> _updatePalette(String url) async {
    try {
      final palette = await PaletteGenerator.fromImageProvider(
        NetworkImage(url),
      );
      final dominantColor =
          palette.dominantColor?.color ?? palette.mutedColor?.color;
      if (dominantColor != null && !isClosed) {
        add(AudioDominantColorUpdated(dominantColor));
      }
    } catch (e) {
      // Ignored
    }
  }

  Future<void> _onPlayQueue(
    AudioPlayQueue event,
    Emitter<AudioState> emit,
  ) async {
    await player.stop();
    if (!event.isRecovery) {
      _trackRetryCounts.clear();
    }
    final queue = List<Map<String, String>>.from(event.tracks);
    final offset = event.startIndex;
    final currentTrack = queue[offset];
    final resumeMs = (state.currentTrack?['videoId'] == currentTrack['videoId'])
        ? state.resumePositionMs
        : null;
    final startPosition = event.initialPosition ??
        ((resumeMs != null && resumeMs > 0)
            ? Duration(milliseconds: resumeMs)
            : Duration.zero);

    emit(
      state.copyWithNullified(dominantColor: true).copyWith(
            queue: queue,
            nativeIndexOffset: offset,
            currentTrack: currentTrack,
            resumePositionMs: 0,
            isFetchingStream: true,
          ),
    );

    if (currentTrack['artworkUrl'] != null &&
        currentTrack['artworkUrl']!.isNotEmpty) {
      _updatePalette(currentTrack['artworkUrl']!);
    }

    final firstSource = await _createAudioSource(
      currentTrack,
      forceRefresh: event.isRecovery,
    );
    // ignore: deprecated_member_use
    _playlist = ConcatenatingAudioSource(
      children: firstSource != null ? [firstSource] : [],
    );

    if (firstSource != null) {
      await player.setAudioSource(
        _playlist,
        initialPosition: startPosition,
      );
    } else {
      await player.setAudioSource(_playlist);
    }

    emit(state.copyWith(isFetchingStream: false));

    if (firstSource != null) {
      final session = await AudioSession.instance;
      await session.setActive(true);
      player.play();
      // Preload next tracks
      _preloadNext(offset + 1, queueOverride: queue);
    } else if (offset + 1 < queue.length && !isClosed) {
      add(AudioPlayQueue(queue, startIndex: offset + 1));
    }
  }

  Future<void> _onCurrentIndexChanged(
    AudioCurrentIndexChanged event,
    Emitter<AudioState> emit,
  ) async {
    final index = event.index;
    if (index != null && state.queue.isNotEmpty) {
      final queueIndex = state.nativeIndexOffset + index;
      if (queueIndex < state.queue.length) {
        final track = state.queue[queueIndex];

        emit(
          state
              .copyWithNullified(dominantColor: true)
              .copyWith(currentTrack: track),
        );

        if (track['artworkUrl'] != null && track['artworkUrl']!.isNotEmpty) {
          _updatePalette(track['artworkUrl']!);
        }

        // Ensure gapless playback by preloading the next 3 tracks instead of just 1
        _preloadNext(queueIndex + 1);
      }
    }
  }

  Future<void> _onSeekToPrevious(
    AudioSeekToPrevious event,
    Emitter<AudioState> emit,
  ) async {
    if (player.hasPrevious) {
      player.seekToPrevious();
    } else {
      if (state.nativeIndexOffset > 0) {
        add(
          AudioPlayQueue(state.queue, startIndex: state.nativeIndexOffset - 1),
        );
      }
    }
  }

  Future<void> _onJumpToQueueIndex(
    AudioJumpToQueueIndex event,
    Emitter<AudioState> emit,
  ) async {
    final targetIndex = event.targetIndex;
    if (targetIndex < 0 || targetIndex >= state.queue.length) return;

    if (targetIndex >= state.nativeIndexOffset &&
        targetIndex < (state.nativeIndexOffset + _playlist.length)) {
      final nativeIndex = targetIndex - state.nativeIndexOffset;
      await player.seek(Duration.zero, index: nativeIndex);
    } else {
      add(AudioPlayQueue(state.queue, startIndex: targetIndex));
    }
  }

  Future<void> _onPlayNext(
    AudioPlayNext event,
    Emitter<AudioState> emit,
  ) async {
    if (state.queue.isEmpty || state.currentTrack == null) {
      add(AudioPlayQueue([event.track], startIndex: 0));
      return;
    }

    final currNative = player.currentIndex ?? 0;
    final currQueue = state.nativeIndexOffset + currNative;
    final insertQueueIndex = (currQueue + 1).clamp(0, state.queue.length);
    final insertNativeIndex = (currNative + 1).clamp(0, _playlist.length);

    final newQueue = List<Map<String, String>>.from(state.queue);
    newQueue.insert(insertQueueIndex, event.track);
    emit(state.copyWith(queue: newQueue));

    final source = await _createAudioSource(event.track);
    if (source != null) {
      // ignore: deprecated_member_use
      await _playlist.insert(insertNativeIndex, source);
    }
  }

  Future<void> _onAddToQueue(
    AudioAddToQueue event,
    Emitter<AudioState> emit,
  ) async {
    if (state.queue.isEmpty || state.currentTrack == null) {
      add(AudioPlayQueue([event.track], startIndex: 0));
      return;
    }

    final newQueue = List<Map<String, String>>.from(state.queue)
      ..add(event.track);
    emit(state.copyWith(queue: newQueue));

    // If preloading is near the end, ensure next track is queued
    _preloadNext(state.nativeIndexOffset + _playlist.length);
  }

  Future<AudioSource?> _createAudioSource(
    Map<String, String> track, {
    bool forceRefresh = false,
  }) async {
    final videoId = track['videoId'];
    if (videoId == null) return null;

    try {
      // Offline/Local check first
      final dbDownload = await DatabaseService.instance.getDownload(videoId);
      String? audioUrl;

      if (dbDownload != null) {
        audioUrl = 'file://${dbDownload['filePath']}';
      } else {
        final infoResult = await PythonService.getStreamUrl(
          videoId,
          forceRefresh: forceRefresh,
        );
        if (infoResult is Success<Map<String, String?>>) {
          audioUrl = infoResult.data['url'];
        }
      }

      if (audioUrl != null && audioUrl.isNotEmpty) {
        Uri? artUri;
        if (track['artworkUrl'] != null && track['artworkUrl']!.isNotEmpty) {
          artUri = Uri.tryParse(track['artworkUrl']!);
        }
        return AudioSource.uri(
          Uri.parse(audioUrl),
          tag: MediaItem(
            id: videoId,
            album: 'Ember Music',
            artist: track['artist'] ?? 'Unknown Artist',
            title: track['title'] ?? 'Unknown',
            artUri: artUri,
          ),
        );
      }
    } catch (e) {
      debugPrint("Error fetching track url for Queue: $e");
    }
    return null;
  }

  Future<void> _onPlayerError(PlayerException error) async {
    if (isClosed || _isRecoveringError) return;
    _isRecoveringError = true;
    try {
      final currNative = error.index ?? player.currentIndex ?? 0;
      final currQueueIndex = state.nativeIndexOffset + currNative;
      if (currQueueIndex < 0 || currQueueIndex >= state.queue.length) return;

      final track = state.queue[currQueueIndex];
      final videoId = track['videoId'];
      final resumePos = player.position;
      debugPrint(
        "Player error (${error.code}: ${error.message}) on $videoId at ${resumePos.inSeconds}s",
      );

      if (videoId != null && (_trackRetryCounts[videoId] ?? 0) < 2) {
        _trackRetryCounts[videoId] = (_trackRetryCounts[videoId] ?? 0) + 1;
        await PythonService.invalidateStreamUrl(videoId);
        if (!isClosed) {
          add(
            AudioPlayQueue(
              state.queue,
              startIndex: currQueueIndex,
              initialPosition: resumePos > const Duration(seconds: 2)
                  ? resumePos
                  : Duration.zero,
              isRecovery: true,
            ),
          );
          return;
        }
      }

      if (currQueueIndex + 1 < state.queue.length && !isClosed) {
        add(AudioPlayQueue(state.queue, startIndex: currQueueIndex + 1));
      }
    } finally {
      _isRecoveringError = false;
    }
  }

  Future<void> _handlePlaybackCompleted() async {
    if (isClosed || _isHandlingCompletion) return;
    _isHandlingCompletion = true;
    try {
      final currNative = player.currentIndex ?? 0;
      final nextQueueIndex = state.nativeIndexOffset + currNative + 1;
      var activeQueue = state.queue;

      if (nextQueueIndex >= activeQueue.length) {
        activeQueue = await _checkAndLoadRadio(baseQueue: activeQueue);
      }

      if (nextQueueIndex < activeQueue.length && !isClosed) {
        if (nextQueueIndex < state.nativeIndexOffset + _playlist.length) {
          final targetNative = nextQueueIndex - state.nativeIndexOffset;
          await player.seek(Duration.zero, index: targetNative);
          final session = await AudioSession.instance;
          await session.setActive(true);
          player.play();
        } else {
          add(AudioPlayQueue(activeQueue, startIndex: nextQueueIndex));
        }
      }
    } finally {
      _isHandlingCompletion = false;
    }
  }

  Future<bool> _addTrackToPlaylist(
    int index,
    List<Map<String, String>> currentQueue,
  ) async {
    if (index >= currentQueue.length) return false;

    final track = currentQueue[index];
    final audioSource = await _createAudioSource(track);
    if (audioSource != null) {
      // ignore: deprecated_member_use
      await _playlist.add(audioSource);
      return true;
    }
    return false;
  }

  Future<void> _preloadNext(
    int nextIndexBase, {
    List<Map<String, String>>? queueOverride,
  }) async {
    if (_isPreloading || isClosed) return;
    _isPreloading = true;
    try {
      var activeQueue = queueOverride ?? state.queue;

      // Check if we are nearing the end of the explicit queue dynamically.
      if (nextIndexBase + 2 >= activeQueue.length) {
        activeQueue = await _checkAndLoadRadio(baseQueue: activeQueue);
      }

      // Keep up to 3 upcoming tracks queued in _playlist without breaking early
      // when _playlist already contains prefetched tracks ahead of nextIndexBase.
      var nextToAppend = state.nativeIndexOffset + _playlist.length;
      while (!isClosed &&
          nextToAppend < activeQueue.length &&
          nextToAppend < nextIndexBase + 3) {
        final added = await _addTrackToPlaylist(nextToAppend, activeQueue);
        if (!added) break;
        nextToAppend = state.nativeIndexOffset + _playlist.length;
      }
    } finally {
      _isPreloading = false;
    }
  }

  Future<List<Map<String, String>>> _checkAndLoadRadio({
    List<Map<String, String>>? baseQueue,
  }) async {
    final activeQueue = baseQueue ?? state.queue;
    if (activeQueue.isEmpty) return activeQueue;

    final lastTrack = activeQueue.last;
    final videoId = lastTrack['videoId'];
    if (videoId == null) return activeQueue;

    try {
      // Fetch Recommendations using the new multi-seed logic
      final recommendedTracks =
          await RecommenderService.instance.getRecommendations([videoId]);
      if (recommendedTracks.isNotEmpty) {
        final startIdx =
            (activeQueue.length - 20) < 0 ? 0 : (activeQueue.length - 20);
        final recentVideoIds =
            activeQueue.skip(startIdx).map((e) => e['videoId']).toSet();
        final newTracks = recommendedTracks
            .where((t) => !recentVideoIds.contains(t['videoId']))
            .toList();

        if (newTracks.isNotEmpty) {
          final updatedQueue = List<Map<String, String>>.from(activeQueue)
            ..addAll(newTracks.take(10)); // Add next 10 recommended tracks
          if (!isClosed) {
            _internalEmitQueueUpdate(updatedQueue);
          }
          return updatedQueue;
        }
      }
    } catch (e) {
      debugPrint("Autoplay fetch error: $e");
    }
    return activeQueue;
  }

  // A helper method if we need to emit explicitly from inside an async background op safely.
  // Note: standard BLoC says all emits must be from on<Event>, so we should properly add an event.
  // Let's refactor this slightly by just appending to the state using a custom event.
  void _internalEmitQueueUpdate(List<Map<String, String>> newQueue) {
    add(AudioUpdateQueue(newQueue));
  }
}
