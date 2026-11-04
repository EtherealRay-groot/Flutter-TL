import 'dart:convert';
import 'dart:typed_data';

import 'ibeacon_codec.dart';

/// FFD0 / FFC3 命令构造（纯 Dart）。
///
/// 所有多字节参数均为**大端**；只有 Company ID 用小端（与固件一致）。
class TlCommands {
  TlCommands._();

  /// FFC3 密码：0x24 0x00 + ASCII 密码。
  static Uint8List verifyPassword(String pwd) => Uint8List.fromList(
        [0x24, 0x00, ...ascii.encode(pwd)],
      );

  /// FFC2 设备名：裸 UTF-8，无 0x24 前缀。
  static Uint8List writeName(String name) =>
      Uint8List.fromList(utf8.encode(name));

  /// FFA6 广播间隔：0x24 + 1B。
  static Uint8List writeInterval(int code) =>
      Uint8List.fromList([0x24, code & 0xFF]);

  /// FFA7 发射功率：0x24 + 1B。
  static Uint8List writeTxPower(int value) =>
      Uint8List.fromList([0x24, value & 0xFF]);

  /// FFA1 iBeacon UUID：0x24 + 16B 原序。
  static Uint8List writeUuid(String hex32) =>
      Uint8List.fromList([0x24, ...IBeaconCodec.uuidHexToBytes(hex32)]);

  /// FFA2 Major：0x24 + 2B 大端。
  static Uint8List writeMajor(int value) =>
      Uint8List.fromList([0x24, ...IBeaconCodec.u16BE(value)]);

  /// FFA3 Minor：0x24 + 2B 大端。
  static Uint8List writeMinor(int value) =>
      Uint8List.fromList([0x24, ...IBeaconCodec.u16BE(value)]);

  /// FFA5 Company ID：0x24 + 2B 小端。
  static Uint8List writeCompany(int value) =>
      Uint8List.fromList([0x24, ...IBeaconCodec.u16LE(value)]);

  /// FFA8 RSSI@1m：0x24 + 1B 有符号。
  static Uint8List writeRssi(int value) =>
      Uint8List.fromList([0x24, value & 0xFF]);

  /// FFD1 开始记录：0x02 + 4B 大端时间戳（秒）+ 2B 大端间隔（秒）。
  static Uint8List startRecording(int epochSec, int intervalSec) =>
      Uint8List.fromList([
        0x02,
        (epochSec >> 24) & 0xFF,
        (epochSec >> 16) & 0xFF,
        (epochSec >> 8) & 0xFF,
        epochSec & 0xFF,
        (intervalSec >> 8) & 0xFF,
        intervalSec & 0xFF,
      ]);

  /// FFD1 停止记录。
  static Uint8List stopRecording() => Uint8List.fromList([0x03]);

  /// FFD1 读取设备信息。
  static Uint8List getInfo() => Uint8List.fromList([0x01]);

  /// FFD1 取消流式读取。
  static Uint8List cancelStream() => Uint8List.fromList([0x09]);

  /// FFD1 读取最近 N 条：0x07 + 1B。
  static Uint8List readRecent(int count) =>
      Uint8List.fromList([0x07, count & 0xFF]);

  /// FFD1 流式读取全部记录：0x08。
  static Uint8List readAll() => Uint8List.fromList([0x08]);

  /// FFD1 分块读取：0x08 + 2B 起始 + 2B 数量（均大端）。
  static Uint8List readChunk(int startIndex, int count) =>
      Uint8List.fromList([
        0x08,
        (startIndex >> 8) & 0xFF,
        startIndex & 0xFF,
        (count >> 8) & 0xFF,
        count & 0xFF,
      ]);

  /// FFD1 按时间段读取：0x0A + 2×4B 大端 epoch 秒。
  static Uint8List readByTime(int startEpochSec, int endEpochSec) =>
      Uint8List.fromList([
        0x0A,
        (startEpochSec >> 24) & 0xFF,
        (startEpochSec >> 16) & 0xFF,
        (startEpochSec >> 8) & 0xFF,
        startEpochSec & 0xFF,
        (endEpochSec >> 24) & 0xFF,
        (endEpochSec >> 16) & 0xFF,
        (endEpochSec >> 8) & 0xFF,
        endEpochSec & 0xFF,
      ]);

  /// FFD1 清除设备记录：0x05。
  static Uint8List clearRecords() => Uint8List.fromList([0x05]);
}
