import 'package:flutter/material.dart';

class DrawingStroke {
  final List<Offset> points;
  final Color color;
  final double strokeWidth;

  const DrawingStroke({
    required this.points,
    required this.color,
    required this.strokeWidth,
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'points': points
          .map((point) => <String, double>{'x': point.dx, 'y': point.dy})
          .toList(growable: false),
      'color': color.toARGB32(),
      'stroke_width': strokeWidth,
    };
  }

  factory DrawingStroke.fromJson(Map<dynamic, dynamic> json) {
    final points = <Offset>[];
    final rawPoints = json['points'];
    if (rawPoints is List) {
      for (final rawPoint in rawPoints) {
        if (rawPoint is! Map) continue;
        final x = rawPoint['x'];
        final y = rawPoint['y'];
        if (x is num && y is num) {
          points.add(
            Offset(x.toDouble().clamp(0.0, 1.0), y.toDouble().clamp(0.0, 1.0)),
          );
        }
      }
    }

    final rawColor = json['color'];
    final rawStrokeWidth = json['stroke_width'];
    return DrawingStroke(
      points: points,
      color: Color(rawColor is num ? rawColor.toInt() : Colors.red.toARGB32()),
      strokeWidth: (rawStrokeWidth is num ? rawStrokeWidth.toDouble() : 3.0)
          .clamp(1.0, 24.0),
    );
  }
}

List<DrawingStroke> drawingStrokesFromJson(dynamic raw) {
  if (raw is! List) return const <DrawingStroke>[];

  final strokes = <DrawingStroke>[];
  for (final value in raw) {
    if (value is Map) {
      final stroke = DrawingStroke.fromJson(value);
      if (stroke.points.isNotEmpty) {
        strokes.add(stroke);
      }
    }
  }
  return strokes;
}

class DrawingPainter extends CustomPainter {
  final List<DrawingStroke> completedStrokes;
  final DrawingStroke? currentStroke;

  DrawingPainter({required this.completedStrokes, this.currentStroke});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    for (final stroke in completedStrokes) {
      _paintStroke(canvas, size, paint, stroke);
    }

    final current = currentStroke;
    if (current != null) {
      _paintStroke(canvas, size, paint, current);
    }
  }

  void _paintStroke(
    Canvas canvas,
    Size size,
    Paint paint,
    DrawingStroke stroke,
  ) {
    if (stroke.points.isEmpty) return;

    paint
      ..color = stroke.color
      ..strokeWidth = stroke.strokeWidth;
    final firstPoint = Offset(
      stroke.points.first.dx * size.width,
      stroke.points.first.dy * size.height,
    );

    if (stroke.points.length == 1) {
      canvas.drawCircle(
        firstPoint,
        stroke.strokeWidth / 2,
        Paint()
          ..color = stroke.color
          ..style = PaintingStyle.fill,
      );
      return;
    }

    final path = Path()..moveTo(firstPoint.dx, firstPoint.dy);
    for (var index = 1; index < stroke.points.length; index++) {
      path.lineTo(
        stroke.points[index].dx * size.width,
        stroke.points[index].dy * size.height,
      );
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant DrawingPainter oldDelegate) => true;
}
