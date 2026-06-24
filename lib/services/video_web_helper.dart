import 'video_web_helper_stub.dart'
    if (dart.library.html) 'video_web_helper_web.dart';

abstract class VideoWebHelper {
  factory VideoWebHelper() => getVideoWebHelper();
  Future<String> fetchBlobUrl(String url);
}
