import 'dart:async';
import 'dart:html' as html;
import 'video_web_helper.dart';

VideoWebHelper getVideoWebHelper() => WebVideoWebHelper();

class WebVideoWebHelper implements VideoWebHelper {
  @override
  Future<String> fetchBlobUrl(String url) async {
    final completer = Completer<String>();
    final xhr = html.HttpRequest();
    xhr.open('GET', url);
    xhr.responseType = 'blob';

    xhr.onLoad.listen((e) {
      if (xhr.status == 200) {
        final blob = xhr.response as html.Blob;
        final blobUrl = html.Url.createObjectUrlFromBlob(blob);
        completer.complete(blobUrl);
      } else {
        completer.completeError('Failed to download video (Status ${xhr.status})');
      }
    });

    xhr.onError.listen((e) {
      completer.completeError('Network connection error while fetching video');
    });

    xhr.send();
    return completer.future;
  }
}
