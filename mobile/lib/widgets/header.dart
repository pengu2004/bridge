import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:mobile/mockConnection.dart';

class Header extends StatefulWidget {
  const Header({super.key});

  @override
  State<Header> createState() => _HeaderState();
}

class _HeaderState extends State<Header> {
  final service = MockConnectionService();
   MockConnectionData? connectionData ;

  initState() {
    super.initState();
    connectionData = service.getConnectionData();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(16.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            connectionData?.laptopName ?? "Unknown Device",
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          Row(
            children: [
              Icon(
                connectionData?.status == ConnectionStatus.connected
                    ? CupertinoIcons.check_mark_circled_solid
                    : CupertinoIcons.xmark_circle_fill,
                color: connectionData?.status == ConnectionStatus.connected
                    ? CupertinoColors.activeGreen
                    : CupertinoColors.systemRed,
              ),
              SizedBox(width: 8),
              Text(
                connectionData?.status == ConnectionStatus.connected
                    ? "Connected"
                    : "Disconnected",
                style: TextStyle(
                  color: connectionData?.status == ConnectionStatus.connected
                      ? CupertinoColors.activeGreen
                      : CupertinoColors.systemRed,
                ),
                
              ),
              SizedBox(width: 8),
              Text(
                "Last Sync: ${connectionData != null ? connectionData!.lastSyncTime.toLocal().toString().split('.')[0] : "N/A"}",
                style: TextStyle(fontSize: 12, color: CupertinoColors.systemGrey),
              ),

            ],
          ),
        ],
      ),
    );
  }
}
