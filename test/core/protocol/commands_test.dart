import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tl_app/core/protocol/commands.dart';

void main() {
  test('verifyPassword prefixes 0x24 0x00 and encodes ASCII', () {
    expect(TlCommands.verifyPassword('1234'),
        [0x24, 0x00, 0x31, 0x32, 0x33, 0x34]);
  });

  test('writeName is raw UTF-8 with no prefix', () {
    expect(TlCommands.writeName('TL8BEEB2'),
        utf8.encode('TL8BEEB2'));
    expect(TlCommands.writeName('温湿'), utf8.encode('温湿'));
  });

  test('single byte params prefix 0x24', () {
    expect(TlCommands.writeInterval(5), [0x24, 0x05]);
    expect(TlCommands.writeTxPower(4), [0x24, 0x04]);
    expect(TlCommands.writeRssi(-61), [0x24, 0xC3]);
  });

  test('uuid is 0x24 plus 16 bytes in order', () {
    final cmd = TlCommands.writeUuid('fda50693a4e24fb1afcfc6eb07647825');
    expect(cmd.length, 17);
    expect(cmd[0], 0x24);
    expect(cmd[1], 0xFD);
    expect(cmd[16], 0x25);
  });

  test('major/minor are big endian, company is little endian', () {
    expect(TlCommands.writeMajor(0x1234), [0x24, 0x12, 0x34]);
    expect(TlCommands.writeMinor(10), [0x24, 0x00, 0x0A]);
    expect(TlCommands.writeCompany(0x004C), [0x24, 0x4C, 0x00]);
  });

  test('startRecording packs timestamp and interval big endian', () {
    expect(
      TlCommands.startRecording(0x01020304, 0x003C),
      [0x02, 0x01, 0x02, 0x03, 0x04, 0x00, 0x3C],
    );
  });

  test('record commands', () {
    expect(TlCommands.stopRecording(), [0x03]);
    expect(TlCommands.getInfo(), [0x01]);
    expect(TlCommands.cancelStream(), [0x09]);
    expect(TlCommands.clearRecords(), [0x05]);
    expect(TlCommands.readRecent(10), [0x07, 0x0A]);
    expect(TlCommands.readAll(), [0x08]);
  });

  test('readChunk packs start and count big endian', () {
    expect(TlCommands.readChunk(30, 30), [0x08, 0x00, 0x1E, 0x00, 0x1E]);
    expect(TlCommands.readChunk(0, 30), [0x08, 0x00, 0x00, 0x00, 0x1E]);
  });

  test('readByTime packs two big endian epochs', () {
    expect(
      TlCommands.readByTime(0x01020304, 0x05060708),
      [0x0A, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08],
    );
  });

  test('depth of returned lists is byte-typed', () {
    expect(TlCommands.readAll(), isA<Uint8List>());
  });
}
