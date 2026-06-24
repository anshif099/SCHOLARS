import 'video_web_helper.dart';

VideoWebHelper getVideoWebHelper() => StubVideoWebHelper();

class StubVideoWebHelper implements VideoWebHelper {
  @override
  Future<String> fetchBlobUrl(String url) async {
    // Return original URL as-is on native platforms
    return url;
  }
}
