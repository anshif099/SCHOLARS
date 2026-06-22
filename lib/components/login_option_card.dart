import 'package:flutter/material.dart';
import 'dart:math' as math;

import '../theme/app_theme.dart';

/// A premium login option card with icon, title, subtitle, 
/// press animations, and a red accent highlight on tap.
class LoginOptionCard extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final int index;

  const LoginOptionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.index = 0,
  });

  @override
  State<LoginOptionCard> createState() => _LoginOptionCardState();
}

class _LoginOptionCardState extends State<LoginOptionCard>
    with SingleTickerProviderStateMixin {
  bool _isPressed = false;
  late AnimationController _entranceController;
  late Animation<double> _slideAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      duration: Duration(milliseconds: 500 + (widget.index * 150)),
      vsync: this,
    );
    _slideAnimation = Tween<double>(begin: 60.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: Curves.easeOutCubic,
      ),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: Curves.easeOut,
      ),
    );
    // Delay the start based on index for staggered effect
    Future.delayed(Duration(milliseconds: 200 + (widget.index * 120)), () {
      if (mounted) _entranceController.forward();
    });
  }

  @override
  void dispose() {
    _entranceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _entranceController,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _slideAnimation.value),
          child: Opacity(
            opacity: _fadeAnimation.value,
            child: child,
          ),
        );
      },
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) {
          setState(() => _isPressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _isPressed = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          transform: _isPressed
              ? Matrix4.diagonal3Values(0.97, 0.97, 1.0)
              : Matrix4.identity(),
          transformAlignment: Alignment.center,
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _isPressed
                  ? AppColors.accentRed.withValues(alpha: 0.04)
                  : AppColors.cardBackground,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: _isPressed
                    ? AppColors.accentRed.withValues(alpha: 0.3)
                    : AppColors.divider,
                width: _isPressed ? 1.5 : 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: _isPressed
                      ? AppColors.accentRed.withValues(alpha: 0.08)
                      : AppColors.primaryNavy.withValues(alpha: 0.06),
                  blurRadius: _isPressed ? 20 : 16,
                  offset: const Offset(0, 4),
                  spreadRadius: _isPressed ? 2 : 0,
                ),
                BoxShadow(
                  color: AppColors.primaryNavy.withValues(alpha: 0.02),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: Row(
              children: [
                // Icon container with gradient background
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    gradient: _isPressed
                        ? AppColors.accentGradient
                        : AppColors.primaryGradient,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: (_isPressed
                                ? AppColors.accentRed
                                : AppColors.primaryNavy)
                            .withValues(alpha: 0.25),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(
                    widget.icon,
                    color: Colors.white,
                    size: 26,
                  ),
                ),

                const SizedBox(width: 16),

                // Text content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: _isPressed
                                  ? AppColors.accentRed
                                  : AppColors.primaryNavy,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.subtitle,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(
                              color: AppColors.textLight,
                              fontSize: 13,
                            ),
                      ),
                    ],
                  ),
                ),

                // Arrow icon
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: _isPressed
                        ? AppColors.accentRed.withValues(alpha: 0.1)
                        : AppColors.primaryNavy.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.arrow_forward_ios_rounded,
                    size: 16,
                    color: _isPressed
                        ? AppColors.accentRed
                        : AppColors.primaryNavy.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Floating decorative dots used for visual interest on the background
class FloatingDots extends StatefulWidget {
  const FloatingDots({super.key});

  @override
  State<FloatingDots> createState() => _FloatingDotsState();
}

class _FloatingDotsState extends State<FloatingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 8),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return CustomPaint(
          painter: _DotsPainter(_controller.value),
          size: Size.infinite,
        );
      },
    );
  }
}

class _DotsPainter extends CustomPainter {
  final double progress;

  _DotsPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final dots = [
      _Dot(0.1, 0.15, 6, AppColors.primaryNavy.withValues(alpha: 0.06)),
      _Dot(0.85, 0.1, 8, AppColors.accentRed.withValues(alpha: 0.05)),
      _Dot(0.7, 0.35, 5, AppColors.primaryNavy.withValues(alpha: 0.04)),
      _Dot(0.15, 0.55, 7, AppColors.accentRed.withValues(alpha: 0.04)),
      _Dot(0.9, 0.6, 4, AppColors.primaryNavy.withValues(alpha: 0.05)),
      _Dot(0.5, 0.85, 6, AppColors.accentRed.withValues(alpha: 0.03)),
      _Dot(0.3, 0.9, 5, AppColors.primaryNavy.withValues(alpha: 0.04)),
    ];

    for (final dot in dots) {
      final x = dot.x * size.width +
          math.sin(progress * 2 * math.pi + dot.x * 10) * 8;
      final y = dot.y * size.height +
          math.cos(progress * 2 * math.pi + dot.y * 10) * 8;
      final paint = Paint()..color = dot.color;
      canvas.drawCircle(Offset(x, y), dot.radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DotsPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _Dot {
  final double x, y, radius;
  final Color color;
  const _Dot(this.x, this.y, this.radius, this.color);
}
