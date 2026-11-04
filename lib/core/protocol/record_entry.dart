/// 一条 Flash 历史记录（8B：时间戳 4B LE、温度 int16 LE ×100、湿度 1B、标志 1B）。
class RecordEntry {
  const RecordEntry({
    required this.timestamp,
    required this.temperature,
    required this.humidity,
  });

  /// epoch 秒。
  final int timestamp;

  /// 摄氏度。
  final double temperature;

  /// 相对湿度 (%)。
  final int humidity;

  @override
  bool operator ==(Object other) =>
      other is RecordEntry &&
      other.timestamp == timestamp &&
      other.temperature == temperature &&
      other.humidity == humidity;

  @override
  int get hashCode => Object.hash(timestamp, temperature, humidity);

  @override
  String toString() =>
      'RecordEntry($timestamp, $temperature, $humidity)';
}
