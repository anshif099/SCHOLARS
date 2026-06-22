import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../components/universal_image.dart';

class NoteImageViewerPage extends StatelessWidget {
  final String title;
  final String imageUrl;

  const NoteImageViewerPage({
    super.key,
    required this.title,
    required this.imageUrl,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: Text(
          title,
          style: GoogleFonts.poppins(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 18,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 4.0,
          child: UniversalImage(
            imageUrl: imageUrl,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) {
              return Center(
                child: Text(
                  'Failed to load image',
                  style: GoogleFonts.poppins(color: Colors.white),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
