// Files a Bot delivered, saved onto the phone in bounded chunks (`file-download`
// with offset and version, 512 KiB each), the same way ds-bot/src/shared/file-chunks.js
// reads them. Each chunk is written before the next is asked for.
import 'dart:convert';
import 'dart:io';

import 'json.dart';

typedef BotCall = Future<Object?> Function(String endpoint, Json payload);

class SavedFile {
  const SavedFile(this.path, this.name, this.mime);

  final String path;
  final String name;
  final String mime;
}

Future<SavedFile> downloadFile(BotCall call, Json target, Directory into, {void Function(int done, int total)? progress}) async {
  final dir = Directory('${into.path}/downloads/${DateTime.now().microsecondsSinceEpoch}');
  await dir.create(recursive: true);
  RandomAccessFile? handle;
  SavedFile? saved;
  try {
    var offset = 0;
    String? version;
    for (;;) {
      final part = asJson(await call('file-download', {...target, 'offset': offset, 'version': ?version}));
      final bytes = base64Decode(jStr(part, 'bytes') ?? '');
      if (handle == null) {
        var name = (jStr(part, 'name') ?? 'file').replaceAll(RegExp(r'[\\/\u0000-\u001f]'), '_');
        if (name == '.' || name == '..' || name.isEmpty) name = 'file';
        final file = File('${dir.path}/$name');
        handle = await file.open(mode: FileMode.write);
        saved = SavedFile(file.path, name, jStr(part, 'mime') ?? 'application/octet-stream');
      }
      await handle.writeFrom(bytes);
      final next = jInt(part, 'nextOffset');
      // Older computers return one whole file without chunk metadata.
      if (next == null) break;
      final partVersion = jStr(part, 'version');
      final done = jBool(part, 'done') == true;
      if (next != offset + bytes.length || (!done && bytes.isEmpty) || (version != null && version != partVersion)) {
        throw const FileSystemException('This file is no longer available');
      }
      progress?.call(next, jInt(part, 'size') ?? next);
      if (done) break;
      offset = next;
      version = partVersion;
    }
    await handle.close();
    handle = null;
    return saved!;
  } on Object {
    await handle?.close();
    handle = null;
    if (await dir.exists()) await dir.delete(recursive: true);
    rethrow;
  }
}
