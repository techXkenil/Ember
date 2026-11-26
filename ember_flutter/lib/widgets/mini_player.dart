import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:ember_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:just_audio/just_audio.dart';

import '../blocs/audio/audio_bloc.dart';
import '../blocs/audio/audio_event.dart';
import '../blocs/audio/audio_state.dart';
import '../blocs/storage/storage_bloc.dart';
import '../blocs/storage/storage_event.dart';
import '../blocs/storage/storage_state.dart';
import '../screens/player/full_player_screen.dart';

class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slideController;
  Animation<double>? _slideAnimation;

  double _dragOffset = 0.0;
  double _viewportWidth = 0.0;
  bool _isDragging = false;
  bool _suppressNextSwitchAnimation = false;

  // Holds the target track briefly right after a committed swipe finishes so
  // there is never a 1-frame snap-back flash before AudioBloc updates state.
  Map<String, String>? _pendingCommitTrack;
  int _pendingCommitDirection = 0; // -1 = swiped left (next), +1 = swiped right (prev)
  int _lastSwitchDirection = 0;

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..addListener(() {
        if (_slideAnimation != null) {
          setState(() {
            _dragOffset = _slideAnimation!.value;
          });
        }
      });
  }

  @override
  void dispose() {
    _slideController.dispose();
    super.dispose();
  }

  int _resolveQueueIndex(AudioState state, AudioPlayer player) {
    final track = state.currentTrack;
    if (track == null || state.queue.isEmpty) return -1;

    final nativeIdx = player.currentIndex;
    if (player.audioSource != null && nativeIdx != null) {
      final candidate = state.nativeIndexOffset + nativeIdx;
      if (candidate >= 0 &&
          candidate < state.queue.length &&
          state.queue[candidate]['videoId'] == track['videoId']) {
        return candidate;
      }
    }

    return state.queue.indexWhere((t) => t['videoId'] == track['videoId']);
  }

  void _animateOffsetTo(
    double target, {
    required Duration duration,
    Curve curve = Curves.easeOutCubic,
    VoidCallback? onCompleted,
  }) {
    _slideController.stop();
    _slideController.duration = duration;
    _slideAnimation = Tween<double>(begin: _dragOffset, end: target).animate(
      CurvedAnimation(parent: _slideController, curve: curve),
    );
    _slideController.forward(from: 0.0).whenComplete(() {
      if (!mounted) return;
      if (_slideController.status == AnimationStatus.completed) {
        onCompleted?.call();
      }
    });
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    _slideController.stop();
    setState(() {
      _isDragging = true;
      _pendingCommitTrack = null;
      _pendingCommitDirection = 0;
    });
  }

  void _onHorizontalDragUpdate(
    DragUpdateDetails details, {
    required bool hasPrevious,
    required bool hasNext,
  }) {
    final width = _viewportWidth > 0 ? _viewportWidth : 240.0;
    final dx = details.delta.dx;
    final nextOffset = _dragOffset + dx;

    // Smooth rubber-band damping if dragging past the start/end of queue.
    final hitsBoundary =
        (nextOffset > 0 && !hasPrevious) || (nextOffset < 0 && !hasNext);
    final dampedDelta = hitsBoundary ? dx * 0.28 : dx;

    setState(() {
      _dragOffset = (_dragOffset + dampedDelta).clamp(-width, width);
    });
  }

  void _onHorizontalDragEnd(
    DragEndDetails details, {
    required AudioBloc audioBloc,
    required Map<String, String>? prevTrack,
    required Map<String, String>? nextTrack,
  }) {
    _isDragging = false;
    final width = _viewportWidth > 0 ? _viewportWidth : 240.0;
    final vx = details.velocity.pixelsPerSecond.dx;

    final commitNext = nextTrack != null &&
        (_dragOffset < -width * 0.28 || (vx < -320 && _dragOffset < -12));
    final commitPrev = prevTrack != null &&
        (_dragOffset > width * 0.28 || (vx > 320 && _dragOffset > 12));

    if (commitNext) {
      _lastSwitchDirection = -1;
      _animateOffsetTo(
        -width,
        duration: const Duration(milliseconds: 170),
        curve: Curves.easeOutCubic,
        onCompleted: () {
          setState(() {
            _pendingCommitTrack = nextTrack;
            _pendingCommitDirection = -1;
            _dragOffset = 0.0;
            _suppressNextSwitchAnimation = true;
          });
          audioBloc.add(AudioSeekToNext());
          Future.delayed(const Duration(milliseconds: 450), () {
            if (!mounted) return;
            if (_pendingCommitTrack != null) {
              setState(() {
                _pendingCommitTrack = null;
                _pendingCommitDirection = 0;
              });
            }
          });
        },
      );
    } else if (commitPrev) {
      _lastSwitchDirection = 1;
      _animateOffsetTo(
        width,
        duration: const Duration(milliseconds: 170),
        curve: Curves.easeOutCubic,
        onCompleted: () {
          setState(() {
            _pendingCommitTrack = prevTrack;
            _pendingCommitDirection = 1;
            _dragOffset = 0.0;
            _suppressNextSwitchAnimation = true;
          });
          audioBloc.add(AudioSeekToPrevious());
          Future.delayed(const Duration(milliseconds: 450), () {
            if (!mounted) return;
            if (_pendingCommitTrack != null) {
              setState(() {
                _pendingCommitTrack = null;
                _pendingCommitDirection = 0;
              });
            }
          });
        },
      );
    } else {
      _animateOffsetTo(
        0.0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _onHorizontalDragCancel() {
    if (!_isDragging) return;
    _isDragging = false;
    _animateOffsetTo(
      0.0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _buildTrackTile(
    Map<String, String> track,
    AudioBloc audioBloc,
    AudioState state,
  ) {
    final showResume =
        audioBloc.player.audioSource == null && state.resumePositionMs != null;
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: CachedNetworkImage(
            imageUrl: track['artworkUrl'] ?? '',
            width: 44,
            height: 44,
            fit: BoxFit.cover,
            placeholder: (c, u) => Container(
              width: 44,
              height: 44,
              color: YTColors.surfaceLight,
            ),
            errorWidget: (c, e, s) => Container(
              width: 44,
              height: 44,
              color: YTColors.surfaceLight,
              child: const Icon(
                Icons.music_note,
                color: YTColors.secondary,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                track['title'] ?? 'Unknown',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                  color: YTColors.primary,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                showResume
                    ? 'Resume at ${_formatMs(state.resumePositionMs!)}'
                    : (track['artist'] ?? 'Unknown Artist'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: showResume
                      ? YTColors.primary.withValues(alpha: 0.8)
                      : YTColors.secondary,
                  fontSize: 13,
                  fontWeight:
                      showResume ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<AudioBloc, AudioState>(
      listenWhen: (prev, curr) =>
          prev.currentTrack?['videoId'] != curr.currentTrack?['videoId'],
      listener: (context, state) {
        if (_pendingCommitTrack != null &&
            state.currentTrack?['videoId'] == _pendingCommitTrack!['videoId']) {
          setState(() {
            _pendingCommitTrack = null;
            _pendingCommitDirection = 0;
          });
        }
      },
      builder: (context, state) {
        final track = state.currentTrack;

        if (track == null) {
          return const SizedBox.shrink();
        }

        final audioBloc = context.read<AudioBloc>();
        final queueIndex = _resolveQueueIndex(state, audioBloc.player);
        final prevTrack =
            (queueIndex > 0) ? state.queue[queueIndex - 1] : null;
        final nextTrack = (queueIndex >= 0 && queueIndex + 1 < state.queue.length)
            ? state.queue[queueIndex + 1]
            : null;

        final displayedTrack = _pendingCommitTrack ?? track;
        final displayedQueueIndex = _pendingCommitTrack != null
            ? (queueIndex - _pendingCommitDirection)
            : queueIndex;
        final trackKey = ValueKey(
          '${displayedTrack['videoId'] ?? ''}_$displayedQueueIndex',
        );
        final playerState = state.playerState;
        final playing = playerState?.playing ?? false;
        final processingState = playerState?.processingState;

        return GestureDetector(
          onVerticalDragEnd: (details) {
            if (details.primaryVelocity != null) {
              if (details.primaryVelocity! < -300) {
                // Swipe up
                _openFullPlayer(context);
              } else if (details.primaryVelocity! > 300) {
                // Swipe down to dismiss
                audioBloc.add(AudioClear());
              }
            }
          },
          onHorizontalDragStart: _onHorizontalDragStart,
          onHorizontalDragUpdate: (details) => _onHorizontalDragUpdate(
            details,
            hasPrevious: prevTrack != null,
            hasNext: nextTrack != null,
          ),
          onHorizontalDragEnd: (details) => _onHorizontalDragEnd(
            details,
            audioBloc: audioBloc,
            prevTrack: prevTrack,
            nextTrack: nextTrack,
          ),
          onHorizontalDragCancel: _onHorizontalDragCancel,
          onTap: () => _openFullPlayer(context),
          child: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16.0, sigmaY: 16.0),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOut,
                color: state.dominantColor?.withValues(alpha: 0.75) ??
                    YTColors.surface.withValues(alpha: 0.85),
                height: 64,
                child: Stack(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 16.0, right: 8.0),
                      child: Row(
                        children: [
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                _viewportWidth = constraints.maxWidth;
                                final w = _viewportWidth;
                                final isSliding = _isDragging ||
                                    _dragOffset.abs() > 0.5;

                                if (isSliding) {
                                  return ClipRect(
                                    child: Stack(
                                      clipBehavior: Clip.hardEdge,
                                      children: [
                                        if (_dragOffset > 0 && prevTrack != null)
                                          Transform.translate(
                                            offset: Offset(_dragOffset - w, 0),
                                            child: _buildTrackTile(
                                              prevTrack,
                                              audioBloc,
                                              state,
                                            ),
                                          ),
                                        Transform.translate(
                                          offset: Offset(_dragOffset, 0),
                                          child: _buildTrackTile(
                                            displayedTrack,
                                            audioBloc,
                                            state,
                                          ),
                                        ),
                                        if (_dragOffset < 0 && nextTrack != null)
                                          Transform.translate(
                                            offset: Offset(_dragOffset + w, 0),
                                            child: _buildTrackTile(
                                              nextTrack,
                                              audioBloc,
                                              state,
                                            ),
                                          ),
                                      ],
                                    ),
                                  );
                                }

                                final skipSwitchAnim =
                                    _suppressNextSwitchAnimation;
                                if (skipSwitchAnim) {
                                  WidgetsBinding.instance
                                      .addPostFrameCallback((_) {
                                    if (mounted) {
                                      _suppressNextSwitchAnimation = false;
                                    }
                                  });
                                }

                                return ClipRect(
                                  child: AnimatedSwitcher(
                                    duration: skipSwitchAnim
                                        ? Duration.zero
                                        : const Duration(milliseconds: 220),
                                    switchInCurve: Curves.easeOutCubic,
                                    switchOutCurve: Curves.easeInCubic,
                                    transitionBuilder: (child, animation) {
                                      final dir = _lastSwitchDirection != 0
                                          ? _lastSwitchDirection
                                          : -1;
                                      final isIncoming = child.key == trackKey;
                                      final offsetTween = isIncoming
                                          ? Tween<Offset>(
                                              begin: Offset(-dir * 0.28, 0),
                                              end: Offset.zero,
                                            )
                                          : Tween<Offset>(
                                              begin: Offset(dir * 0.28, 0),
                                              end: Offset.zero,
                                            );
                                      return FadeTransition(
                                        opacity: animation,
                                        child: SlideTransition(
                                          position:
                                              animation.drive(offsetTween),
                                          child: child,
                                        ),
                                      );
                                    },
                                    child: KeyedSubtree(
                                      key: trackKey,
                                      child: _buildTrackTile(
                                        displayedTrack,
                                        audioBloc,
                                        state,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(width: 4),
                          BlocBuilder<StorageBloc, StorageState>(
                            builder: (context, storage) {
                              final isFav = storage.isFavorite(
                                displayedTrack['videoId'] ?? '',
                              );
                              return IconButton(
                                icon: Icon(
                                  isFav
                                      ? Icons.thumb_up
                                      : Icons.thumb_up_outlined,
                                  color: YTColors.primary,
                                  size: 20,
                                ),
                                onPressed: () {
                                  context.read<StorageBloc>().add(
                                        StorageToggleFavorite(displayedTrack),
                                      );
                                },
                              );
                            },
                          ),
                          Builder(
                            builder: (context) {
                              Widget playPauseBtn;
                              if (state.isFetchingStream ||
                                  processingState == ProcessingState.loading ||
                                  processingState ==
                                      ProcessingState.buffering) {
                                playPauseBtn = Padding(
                                  key: const ValueKey('loading'),
                                  padding: const EdgeInsets.all(12.0),
                                  child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: YTColors.primary,
                                    ),
                                  ),
                                );
                              } else if (playing) {
                                playPauseBtn = IconButton(
                                  key: const ValueKey('pause'),
                                  icon: Icon(
                                    Icons.pause,
                                    color: YTColors.primary,
                                    size: 28,
                                  ),
                                  onPressed: () => audioBloc.add(AudioPause()),
                                );
                              } else {
                                playPauseBtn = IconButton(
                                  key: const ValueKey('play'),
                                  icon: Icon(
                                    Icons.play_arrow,
                                    color: YTColors.primary,
                                    size: 28,
                                  ),
                                  onPressed: () => audioBloc.add(AudioResume()),
                                );
                              }
                              return AnimatedSwitcher(
                                duration: const Duration(milliseconds: 250),
                                transitionBuilder: (child, anim) =>
                                    ScaleTransition(
                                  scale: anim,
                                  child: child,
                                ),
                                child: playPauseBtn,
                              );
                            },
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.skip_next,
                              color: YTColors.primary,
                              size: 28,
                            ),
                            onPressed: () {
                              _lastSwitchDirection = -1;
                              audioBloc.add(AudioSeekToNext());
                            },
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: StreamBuilder<Duration>(
                        stream: audioBloc.player.positionStream,
                        builder: (context, posSnap) {
                          return StreamBuilder<Duration?>(
                            stream: audioBloc.player.durationStream,
                            builder: (context, durSnap) {
                              final duration = durSnap.data ?? Duration.zero;
                              final position = posSnap.data ?? Duration.zero;
                              double progress = 0.0;
                              if (duration.inMilliseconds > 0) {
                                progress = position.inMilliseconds /
                                    duration.inMilliseconds;
                              } else if (audioBloc.player.audioSource == null &&
                                  state.resumePositionMs != null) {
                                int totalMs = _parseDurationString(
                                    displayedTrack['duration']);
                                if (totalMs > 0) {
                                  progress = state.resumePositionMs! / totalMs;
                                }
                              }
                              progress = progress.clamp(0.0, 1.0);
                              return LinearProgressIndicator(
                                value: progress,
                                backgroundColor: Colors.transparent,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  YTColors.primary,
                                ),
                                minHeight: 1.5,
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _openFullPlayer(BuildContext context) {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => const FullPlayerScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(0.0, 1.0);
          const end = Offset.zero;
          var tween = Tween(begin: begin, end: end).chain(CurveTween(curve: Curves.fastOutSlowIn));
          return SlideTransition(position: animation.drive(tween), child: child);
        },
      ),
    );
  }

  String _formatMs(int ms) {
    if (ms <= 0) return '0:00';
    final duration = Duration(milliseconds: ms);
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = duration.inMinutes.remainder(60);
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    if (duration.inHours > 0) {
      return '${duration.inHours}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  int _parseDurationString(String? durationStr) {
    if (durationStr == null || durationStr.isEmpty) return 0;
    final parts = durationStr.split(':');
    if (parts.length == 2) {
      final m = int.tryParse(parts[0]) ?? 0;
      final s = int.tryParse(parts[1]) ?? 0;
      return (m * 60 + s) * 1000;
    } else if (parts.length == 3) {
      final h = int.tryParse(parts[0]) ?? 0;
      final m = int.tryParse(parts[1]) ?? 0;
      final s = int.tryParse(parts[2]) ?? 0;
      return (h * 3600 + m * 60 + s) * 1000;
    }
    return 0;
  }
}
