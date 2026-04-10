class MockConnectionData {
  String laptopName;
  String deviceId;
  ConnectionStatus status;
  DateTime lastSyncTime;
  MockConnectionData({
    required this.laptopName,
    required this.deviceId,
    required this.status,
    required this.lastSyncTime,
  });
}

enum ConnectionStatus { connected, disconnected, error, searching }

class MockConnectionService {
  MockConnectionData getConnectionData() {
    return MockConnectionData(
      laptopName: "Macbook Pro",
      deviceId: "123-456-789",
      status: ConnectionStatus.connected,
      lastSyncTime: DateTime.now().subtract(Duration(minutes: 5)),
    );
  }
}
