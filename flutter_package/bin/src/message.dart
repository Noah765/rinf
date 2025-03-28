import 'dart:io';

import 'package:path/path.dart';
import 'package:watcher/watcher.dart';
import 'package:chalkdart/chalkstrings.dart';

import 'config.dart';
import 'common.dart';
import 'internet.dart';
import 'progress.dart';

enum MarkType {
  dartSignal,
  dartSignalBinary,
  rustSignal,
  rustSignalBinary,
  rustAttribute,
}

class MessageMark {
  MarkType markType;
  String name;
  int id;
  MessageMark(
    this.markType,
    this.name,
    this.id,
  );
}

Future<void> generateMessageCode({
  bool silent = false,
  required RinfConfigMessage messageConfig,
}) async {
  final fillingBar = ProgressBar(
    total: 8,
    width: 16,
    silent: silent,
  );
  // Prepare paths.
  final flutterProjectPath = Directory.current;
  final protoPath = flutterProjectPath.uri.join(messageConfig.inputDir);
  final rustOutputPath =
      flutterProjectPath.uri.join(messageConfig.rustOutputDir);
  final dartOutputPath =
      flutterProjectPath.uri.join(messageConfig.dartOutputDir);
  await Directory.fromUri(rustOutputPath).create(recursive: true);
  await emptyDirectory(rustOutputPath);
  await Directory.fromUri(dartOutputPath).create(recursive: true);
  await emptyDirectory(dartOutputPath);

  // Get the list of `.proto` files.
  // Also, analyze marked messages in `.proto` files.
  fillingBar.desc = 'Collecting Protobuf files';
  final resourcesInFolders = <String, List<String>>{};
  await collectProtoFiles(
    Directory.fromUri(protoPath),
    Directory.fromUri(protoPath),
    resourcesInFolders,
  );
  final markedMessagesAll = await analyzeMarkedMessages(
    protoPath,
    resourcesInFolders,
  );
  fillingBar.increment();

  // Include `package` statement in `.proto` files.
  // Package name should be the same as the filename
  // because Rust filenames are written with package name
  // and Dart filenames are written with the `.proto` filename.
  fillingBar.desc = 'Normalizing Protobuf files';
  for (final entry in resourcesInFolders.entries) {
    final subPath = entry.key;
    final resourceNames = entry.value;
    for (final resourceName in resourceNames) {
      final protoFile = File.fromUri(
        protoPath.join(subPath).join('$resourceName.proto'),
      );
      final lines = await protoFile.readAsLines();
      List<String> outputLines = [];
      for (var line in lines) {
        final packagePattern = r'^package\s+[a-zA-Z_][a-zA-Z0-9_\.]*\s*[^=];$';
        if (RegExp(packagePattern).hasMatch(line.trim())) {
          continue;
        } else if (line.trim().startsWith('syntax')) {
          continue;
        } else {
          outputLines.add(line);
        }
      }
      outputLines.insert(0, 'package $resourceName;');
      outputLines.insert(0, 'syntax = "proto3";');
      await protoFile.writeAsString(outputLines.join('\n') + '\n');
    }
  }
  fillingBar.increment();

  // Generate Rust message files.
  fillingBar.desc = 'Generating Rust message files';
  if (isInternetConnected) {
    final cargoInstallCommand = await Process.run('cargo', [
      'install',
      'protoc-gen-prost',
      ...(messageConfig.rustSerde ? ['protoc-gen-prost-serde'] : [])
    ]);
    if (cargoInstallCommand.exitCode != 0) {
      throw Exception(cargoInstallCommand.stderr);
    }
  }
  for (final entry in resourcesInFolders.entries) {
    final subPath = entry.key;
    final resourceNames = entry.value;
    await Directory.fromUri(rustOutputPath.join(subPath))
        .create(recursive: true);
    if (resourceNames.isEmpty) {
      continue;
    }
    final protoPaths = <String>[];
    for (final key in resourcesInFolders.keys) {
      final joinedPath = protoPath.join(key).toFilePath();
      protoPaths.add('--proto_path=$joinedPath');
    }
    final rustFullPath = rustOutputPath.join(subPath).toFilePath();
    final protocRustResult = await Process.run('protoc', [
      ...protoPaths,
      '--prost_out=$rustFullPath',
      ...(messageConfig.rustSerde ? ['--prost-serde_out=$rustFullPath'] : []),
      ...resourceNames.map((name) => '$name.proto'),
      ...markedMessagesAll.values.fold<List<String>>([], (args, messages) {
        messages.values.forEach((messages) => args.addAll(messages
            .where((message) => message.markType == MarkType.rustAttribute)
            .map((message) => message.name)));
        return args;
      })
    ]);
    if (protocRustResult.exitCode != 0) {
      throw Exception(protocRustResult.stderr);
    }
  }
  fillingBar.increment();

  // Generate `mod.rs` for `messages` module in Rust.
  fillingBar.desc = 'Writing `mod.rs` files';
  for (final entry in resourcesInFolders.entries) {
    final subPath = entry.key;
    final resourceNames = entry.value;
    final modRsLines = <String>[];
    for (final resourceName in resourceNames) {
      modRsLines.add('pub mod $resourceName;');
      modRsLines.add('pub use $resourceName::*;');
    }
    for (final otherSubPath in resourcesInFolders.keys) {
      if (otherSubPath != subPath && otherSubPath.contains(subPath)) {
        final subPathSplitted = subPath
            .trim()
            .split('/')
            .where(
              (element) => element.isNotEmpty,
            )
            .toList();
        final otherSubPathSplitted = otherSubPath
            .split('/')
            .where(
              (element) => element.isNotEmpty,
            )
            .toList();
        ;
        if (subPathSplitted.length != otherSubPathSplitted.length - 1) {
          continue;
        }
        var isOtherChild = true;
        for (int i = 0; i < subPathSplitted.length; i++) {
          if (subPathSplitted[i] != subPathSplitted[i]) {
            isOtherChild = false;
            break;
          }
        }
        if (!isOtherChild) {
          continue;
        }
        final childName = otherSubPathSplitted.last;
        modRsLines.add('mod $childName;');
        modRsLines.add('pub use $childName::*;');
      }
    }
    if (subPath == '/') {
      modRsLines.add('mod generated;');
      modRsLines.add('pub use generated::*;');
    }
    final modRsContent = modRsLines.join('\n');
    await File.fromUri(rustOutputPath.join(subPath).join('mod.rs'))
        .writeAsString(modRsContent);
  }

  fillingBar.increment();

  // Generate Dart message files.
  fillingBar.desc = 'Generating Dart message files';
  if (isInternetConnected) {
    final pubGlobalActivateCommand = await Process.run('dart', [
      'pub',
      'global',
      'activate',
      'protoc_plugin',
      '^21.0.0',
    ]);
    if (pubGlobalActivateCommand.exitCode != 0) {
      throw Exception(pubGlobalActivateCommand.stderr);
    }
  }
  for (final entry in resourcesInFolders.entries) {
    final subPath = entry.key;
    final resourceNames = entry.value;
    await Directory.fromUri(dartOutputPath.join(subPath))
        .create(recursive: true);
    if (resourceNames.isEmpty) {
      continue;
    }
    final protoPaths = <String>[];
    for (final key in resourcesInFolders.keys) {
      final joinedPath = protoPath.join(key).toFilePath();
      protoPaths.add('--proto_path=$joinedPath');
    }
    final dartFullPath = dartOutputPath.join(subPath).toFilePath();
    final protocDartResult = await Process.run(
      'protoc',
      [
        ...protoPaths,
        '--dart_out=$dartFullPath',
        ...resourceNames.map((name) => '$name.proto'),
      ],
    );
    if (protocDartResult.exitCode != 0) {
      throw Exception(protocDartResult.stderr);
    }
  }
  fillingBar.increment();

  // Generate `all.dart` for `messages` module in Dart.
  fillingBar.desc = 'Writing `all.dart` file';
  final exportsDartLines = <String>[];
  exportsDartLines.add("export './generated.dart';");
  for (final entry in resourcesInFolders.entries) {
    var subPath = entry.key;
    if (subPath == '/') {
      subPath = '';
    }
    final resourceNames = entry.value;
    for (final resourceName in resourceNames) {
      exportsDartLines.add("export './$subPath$resourceName.pb.dart';");
    }
  }
  final exportsDartContent = exportsDartLines.join('\n');
  await File.fromUri(dartOutputPath.join('all.dart'))
      .writeAsString(exportsDartContent);
  fillingBar.increment();

  // Prepare communication channels between Dart and Rust.
  fillingBar.desc = 'Writing communication channels and streams';
  for (final entry in markedMessagesAll.entries) {
    final subPath = entry.key;
    final filesAndMarks = entry.value;
    for (final entry in filesAndMarks.entries) {
      if (entry.value.isEmpty) {
        continue;
      }
      final filename = entry.key;
      final dartPath = dartOutputPath.join(subPath).join('$filename.pb.dart');
      final dartFile = File.fromUri(dartPath);
      final dartContent = await dartFile.readAsString();
      final rustPath = rustOutputPath.join(subPath).join('$filename.rs');
      final rustFile = File.fromUri(rustPath);
      final rustContent = await rustFile.readAsString();
      if (!dartContent.contains("import 'dart:typed_data'")) {
        await insertTextToFile(
          dartPath,
          """
// ignore_for_file: invalid_language_version_override

import 'dart:async';
import 'dart:typed_data';
import 'package:rinf/rinf.dart';
""",
          atFront: true,
        );
      }
      if (!rustContent.contains('use std::sync')) {
        await insertTextToFile(
          rustPath,
          '''
#![allow(unused_imports)]

use prost::Message;
use rinf::{
    debug_print, send_rust_signal, signal_channel,
    DartSignal, SignalReceiver, SignalSender,
};
use std::sync::LazyLock;

''',
          atFront: true,
        );
      }
      final markedMessages = entry.value;
      for (final markedMessage in markedMessages) {
        final messageName = markedMessage.name;
        final markType = markedMessage.markType;
        final camelName = pascalToCamel(messageName);
        final snakeName = pascalToSnake(messageName);
        if (markType == MarkType.dartSignal ||
            markType == MarkType.dartSignalBinary) {
          await insertTextToFile(
            rustPath,
            '''
type ${messageName}Channel = LazyLock<(
    SignalSender<DartSignal<${normalizePascal(messageName)}>>,
    SignalReceiver<DartSignal<${normalizePascal(messageName)}>>,
)>;
pub static ${snakeName.toUpperCase()}_CHANNEL: ${messageName}Channel =
    LazyLock::new(signal_channel);

impl ${normalizePascal(messageName)} {
    pub fn get_dart_signal_receiver() -> SignalReceiver<DartSignal<Self>> {
        ${snakeName.toUpperCase()}_CHANNEL.1.clone()
    }
}
''',
          );
          if (markType == MarkType.dartSignal) {
            await insertTextToFile(
              dartPath,
              '''
extension ${messageName}Ext on $messageName{
  void sendSignalToRust() {
    sendDartSignal(
      ${markedMessage.id},
      this.writeToBuffer(),
      Uint8List(0),
    );
  }
}
''',
            );
          }
        }
        if (markType == MarkType.dartSignalBinary) {
          await insertTextToFile(
            dartPath,
            '''
extension ${messageName}Ext on $messageName{
  void sendSignalToRust(Uint8List binary) {
    sendDartSignal(
      ${markedMessage.id},
      this.writeToBuffer(),
      binary,
    );
  }
}
''',
          );
        }
        if (markType == MarkType.rustSignal ||
            markType == MarkType.rustSignalBinary) {
          await insertTextToFile(
            dartPath,
            '''
static final rustSignalStream =
    ${camelName}Controller.stream.asBroadcastStream();
''',
            after: 'class $messageName extends \$pb.GeneratedMessage {',
          );
          await insertTextToFile(
            dartPath,
            '''
final ${camelName}Controller = StreamController<RustSignal<$messageName>>();
''',
          );
        }
        if (markType == MarkType.rustSignal) {
          await insertTextToFile(
            rustPath,
            '''
impl ${normalizePascal(messageName)} {
    pub fn send_signal_to_dart(&self) {
        let result = send_rust_signal(
            ${markedMessage.id},
            self.encode_to_vec(),
            Vec::new(),
        );
        if let Err(error) = result {
            debug_print!("{error}\\n{self:?}");
        }
    }
}
''',
          );
        }
        if (markType == MarkType.rustSignalBinary) {
          await insertTextToFile(
            rustPath,
            '''
impl ${normalizePascal(messageName)} {
    pub fn send_signal_to_dart(&self, binary: Vec<u8>) {
        let result = send_rust_signal(
            ${markedMessage.id},
            self.encode_to_vec(),
            binary,
        );
        if let Err(error) = result {
            debug_print!("{error}\\n{self:?}");
        }
    }
}
''',
          );
        }
      }
    }
  }

  // Get ready to handle received signals in Rust.
  var rustReceiveScript = '';
  rustReceiveScript += '''
#![allow(unused_imports)]
#![allow(unused_mut)]

use super::*;
use prost::Message;
use rinf::{DartSignal, RinfError};
use std::collections::HashMap;
use std::sync::LazyLock;

type Handler = dyn Fn(&[u8], &[u8]) -> Result<(), RinfError> + Send + Sync;
type DartSignalHandlers = HashMap<i32, Box<Handler>>;
static DART_SIGNAL_HANDLERS: LazyLock<DartSignalHandlers> = LazyLock::new(|| {
    let mut hash_map: DartSignalHandlers = HashMap::new();
''';
  for (final entry in markedMessagesAll.entries) {
    final subpath = entry.key;
    final files = entry.value;
    for (final entry in files.entries) {
      final markedMessages = entry.value;
      for (final markedMessage in markedMessages) {
        final markType = markedMessage.markType;
        if (markType == MarkType.dartSignal ||
            markType == MarkType.dartSignalBinary) {
          final messageName = markedMessage.name;
          final snakeName = pascalToSnake(messageName);
          var modulePath = subpath.replaceAll('/', '::');
          modulePath = modulePath == '::' ? '' : modulePath;
          rustReceiveScript += '''
hash_map.insert(
    ${markedMessage.id},
    Box::new(|message_bytes: &[u8], binary: &[u8]| {
        let message =
            ${normalizePascal(messageName)}::decode(message_bytes)
            .map_err(|_| RinfError::CannotDecodeMessage)?;
        let dart_signal = DartSignal {
            message,
            binary: binary.to_vec(),
        };
        ${snakeName.toUpperCase()}_CHANNEL.0.send(dart_signal);
        Ok(())
    }),
);
''';
        }
      }
    }
  }
  rustReceiveScript += '''
    hash_map
});

pub fn assign_dart_signal(
    message_id: i32,
    message_bytes: &[u8],
    binary: &[u8]
) -> Result<(), RinfError> {
    let signal_handler = match DART_SIGNAL_HANDLERS.get(&message_id) {
        Some(inner) => inner,
        None => return Err(RinfError::NoSignalHandler),
    };
    signal_handler(message_bytes, binary)
}
''';
  await File.fromUri(rustOutputPath.join('generated.rs'))
      .writeAsString(rustReceiveScript);

  // format rust code
  var rustFiles = <String>[];
  for (final entry in resourcesInFolders.entries) {
    for (final file in entry.value) {
      rustFiles.add(
        rustOutputPath.join(entry.key).join('$file.rs').toFilePath(),
      );
    }
  }
  for (final rootMod in ['generated.rs', 'mod.rs']) {
    rustFiles.add(rustOutputPath.join(rootMod).toFilePath());
  }
  await Process.run('rustfmt', rustFiles);

  // Get ready to handle received signals in Dart.
  var dartReceiveScript = '';
  dartReceiveScript += """
// ignore_for_file: unused_import

import 'dart:typed_data';
import 'package:rinf/rinf.dart';

final rustSignalHandlers = <int, void Function(Uint8List, Uint8List)>{
""";
  for (final entry in markedMessagesAll.entries) {
    final subpath = entry.key;
    final files = entry.value;
    for (final entry in files.entries) {
      final filename = entry.key;
      final markedMessages = entry.value;
      for (final markedMessage in markedMessages) {
        final markType = markedMessage.markType;
        if (markType == MarkType.rustSignal ||
            markType == MarkType.rustSignalBinary) {
          final messageName = markedMessage.name;
          final camelName = pascalToCamel(messageName);
          final importPath = subpath == '/'
              ? '$filename.pb.dart'
              : '$subpath$filename.pb.dart';
          if (!dartReceiveScript.contains(importPath)) {
            dartReceiveScript = """
import './$importPath' as $filename;
""" +
                dartReceiveScript;
          }
          dartReceiveScript += '''
${markedMessage.id}: (Uint8List messageBytes, Uint8List binary) {
  final message = $filename.$messageName.fromBuffer(messageBytes);
  final rustSignal = RustSignal(
    message,
    binary,
  );
  $filename.${camelName}Controller.add(rustSignal);
},
''';
        }
      }
    }
  }
  dartReceiveScript += '''
};

void assignRustSignal(int messageId, Uint8List messageBytes, Uint8List binary) {
  rustSignalHandlers[messageId]!(messageBytes, binary);
}
''';
  await File.fromUri(dartOutputPath.join('generated.dart'))
      .writeAsString(dartReceiveScript);
  fillingBar.increment();

  // Notify that it's done
  fillingBar.desc = 'Message code in Dart and Rust is now ready 🎉';
  fillingBar.increment();
}

Future<void> watchAndGenerateMessageCode(
    {required RinfConfigMessage messageConfig}) async {
  final currentDirectory = Directory.current;
  final messagesPath = join(currentDirectory.path, 'messages');
  final messagesDirectory = Directory(messagesPath);

  // Listen to keystrokes in the CLI.
  var shouldQuit = false;
  stdin.echoMode = false;
  stdin.lineMode = false;
  stdin.listen((keyCodes) {
    for (final keyCode in keyCodes) {
      final key = String.fromCharCode(keyCode);
      if (key.toLowerCase() == 'q') {
        shouldQuit = true;
      }
    }
  });

  // Watch `.proto` files.
  final watcher = PollingDirectoryWatcher(messagesDirectory.path);
  var generated = true;
  print('Watching `.proto` files, press `q` to stop watching');
  print('Nothing changed yet'.dim);
  watcher.events.listen((event) {
    if (event.path.endsWith('.proto') && generated) {
      var eventType = event.type.toString();
      eventType = eventType[0].toUpperCase() + eventType.substring(1);
      final fileRelativePath = relative(event.path, from: messagesPath);
      final now = DateTime.now();
      final formattedTime =
          "${now.year}-${now.month.toString().padLeft(2, '0')}-"
          "${now.day.toString().padLeft(2, '0')} "
          "${now.hour.toString().padLeft(2, '0')}:"
          "${now.minute.toString().padLeft(2, '0')}:"
          "${now.second.toString().padLeft(2, '0')}";
      removeCliLines(1);
      print('$eventType: $fileRelativePath ($formattedTime)'.dim);
      generated = false;
    }
  });
  while (true) {
    await Future.delayed(Duration(seconds: 1));
    if (shouldQuit) {
      exit(0);
    }
    if (!generated) {
      try {
        await generateMessageCode(silent: true, messageConfig: messageConfig);
      } catch (error) {
        removeCliLines(1);
        print(error.toString().trim().red);
      }
      generated = true;
    }
  }
}

Future<void> collectProtoFiles(
  Directory rootDirectory,
  Directory directory,
  Map<String, List<String>> resourcesInFolders,
) async {
  final resources = <String>[];
  await for (final entity in directory.list()) {
    if (entity is File) {
      final filename = entity.uri.pathSegments.last;
      if (filename.endsWith('.proto')) {
        final parts = filename.split('.');
        parts.removeLast(); // Remove the extension from the filename.
        final fileNameWithoutExtension = parts.join('.');
        resources.add(fileNameWithoutExtension);
      }
    } else if (entity is Directory) {
      await collectProtoFiles(
        rootDirectory,
        entity,
        resourcesInFolders,
      ); // Recursive call for subdirectories
    }
  }
  var subPath = directory.path.replaceFirst(rootDirectory.path, '');
  subPath = subPath.replaceAll('\\', '/'); // For Windows
  subPath = '$subPath/'; // Indicate that it's a folder, not a file
  resourcesInFolders[subPath] = resources;
}

Future<void> emptyDirectory(Uri directoryPath) async {
  final directory = Directory.fromUri(directoryPath);

  if (await directory.exists()) {
    await for (final entity in directory.list()) {
      if (entity is File) {
        await entity.delete();
      } else if (entity is Directory) {
        await entity.delete(recursive: true);
      }
    }
  }
}

Future<void> insertTextToFile(
  Uri filePath,
  String textToAppend, {
  bool atFront = false,
  String? after,
}) async {
  // Read the existing content of the file
  final file = File.fromUri(filePath);
  if (!(await file.exists())) {
    await file.create(recursive: true);
  }
  String fileContent = await file.readAsString();

  // Append the new text to the existing content
  if (atFront) {
    fileContent = textToAppend + '\n' + fileContent;
  } else if (after != null) {
    fileContent = fileContent.replaceFirst(after, after + textToAppend);
  } else {
    fileContent = fileContent + '\n' + textToAppend;
  }

  // Write the updated content back to the file
  await file.writeAsString(fileContent);
}

Future<Map<String, Map<String, List<MessageMark>>>> analyzeMarkedMessages(
  Uri protoPath,
  Map<String, List<String>> resourcesInFolders,
) async {
  final messageMarks = <String, Map<String, List<MessageMark>>>{};
  for (final entry in resourcesInFolders.entries) {
    final subpath = entry.key;
    final filenames = entry.value;
    final markedMessagesInFiles = <String, List<MessageMark>>{};
    for (final filename in filenames) {
      markedMessagesInFiles[filename] = [];
    }
    messageMarks[subpath] = markedMessagesInFiles;
  }
  int messageId = 0;
  for (final entry in resourcesInFolders.entries) {
    final subPath = entry.key;
    for (final filename in entry.value) {
      final protoFile = File.fromUri(
        protoPath.join(subPath).join('$filename.proto'),
      );
      final content = await protoFile.readAsString();
      final regExp = RegExp(r'{[^}]*}');
      final attrExp = RegExp(r'(?<=\[RUST-ATTRIBUTE\().*(?=\)\])');

      // Remove all { ... } blocks from the string
      final contentWithoutBlocks = content.replaceAll(regExp, ';');
      final statements = contentWithoutBlocks.split(';');
      for (final statementRaw in statements) {
        final statement = statementRaw.trim();
        // To find "}\n\n// [RUST-SIGNAL]",
        // `contains` is used instead of `startsWith`
        String? messageName = null;
        final lines = statement.split('\n');
        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.startsWith('message')) {
            messageName = trimmed.replaceFirst('message', '').trim();
          }
        }
        if (messageName == null) {
          // When the statement is not a message
          continue;
        }

        // Find [DART-SIGNAL]
        if (statement.contains('[DART-SIGNAL]')) {
          if (statement.contains('DART-SIGNAL-BINARY')) {
            throw Exception(
              '`DART-SIGNAL` and `DART-SIGNAL-BINARY` cannot be used together',
            );
          }
          messageMarks[subPath]![filename]!.add(MessageMark(
            MarkType.dartSignal,
            messageName,
            messageId,
          ));
        } else if (statement.contains('[DART-SIGNAL-BINARY]')) {
          messageMarks[subPath]![filename]!.add(MessageMark(
            MarkType.dartSignalBinary,
            messageName,
            messageId,
          ));
        }

        // Find [RUST-SIGNAL]
        if (statement.contains('[RUST-SIGNAL]')) {
          if (statement.contains('RUST-SIGNAL-BINARY')) {
            throw Exception(
              '`RUST-SIGNAL` and `RUST-SIGNAL-BINARY` cannot be used together',
            );
          }
          messageMarks[subPath]![filename]!.add(MessageMark(
            MarkType.rustSignal,
            messageName,
            messageId,
          ));
        } else if (statement.contains('[RUST-SIGNAL-BINARY]')) {
          messageMarks[subPath]![filename]!.add(MessageMark(
            MarkType.rustSignalBinary,
            messageName,
            messageId,
          ));
        }

        // Find [RUST-ATTRIBUTE(...)]
        var attr = attrExp.stringMatch(statement);
        if (attr != null) {
          messageMarks[subPath]![filename]!.add(MessageMark(
            MarkType.rustAttribute,
            "--prost_opt=type_attribute=$filename.$messageName=${attr.replaceAll(",", "\\,")}",
            -1,
          ));
          continue;
        }

        messageId += 1;
      }
    }
  }
  return messageMarks;
}

String pascalToCamel(String input) {
  if (input.isEmpty) {
    return input;
  }
  return input[0].toLowerCase() + input.substring(1);
}

String pascalToSnake(String input) {
  if (input.isEmpty) {
    return input;
  }
  final camelCase = pascalToCamel(input);
  String snakeCase = camelCase.replaceAllMapped(
      RegExp(r'[A-Z]'), (Match match) => '_${match.group(0)?.toLowerCase()}');
  return snakeCase;
}

String snakeToCamel(String input) {
  List<String> parts = input.split('_');
  String camelCase = parts[0];
  for (int i = 1; i < parts.length; i++) {
    camelCase += parts[i][0].toUpperCase() + parts[i].substring(1);
  }
  return camelCase;
}

/// Converts a string `HeLLLLLLLo` to `HeLlllllLo`,
/// just like `protoc-gen-prost` does.
String normalizePascal(String input) {
  var upperStreak = '';
  var result = '';
  for (final character in input.split('')) {
    if (character.toUpperCase() == character) {
      upperStreak += character;
    } else {
      final fixedUpperStreak = lowerBetween(upperStreak);
      upperStreak = '';
      result += fixedUpperStreak;
      result += character;
    }
  }
  result += lowerExceptFirst(upperStreak);
  return result;
}

String lowerBetween(String input) {
  if (input.isEmpty) {
    return input;
  }
  if (input.length == 1) {
    return input.toUpperCase(); // Keep the single character in uppercase
  }
  String firstChar = input.substring(0, 1);
  String lastChar = input.substring(input.length - 1);
  String middleChars = input.substring(1, input.length - 1).toLowerCase();
  return '$firstChar$middleChars$lastChar';
}

String lowerExceptFirst(String input) {
  if (input.isEmpty) {
    return input;
  }
  String firstChar = input.substring(0, 1);
  String restOfString = input.substring(1).toLowerCase();
  return '$firstChar$restOfString';
}
