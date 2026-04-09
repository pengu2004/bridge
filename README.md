# Bridge

P2P file sync between your laptop and phone over local WiFi.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              LAPTOP (macOS)                                  │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                     Menu Bar App (SwiftUI)                           │   │
│   │   [🔄 Bridge]                                                        │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                    Daemon Core (Swift Package)                       │   │
│   │   mDNS Advertiser | TCP Server | Sync Engine | File Watcher          │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                     ▲
                                     │ mDNS + TCP/TLS
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              PHONE (React Native)                           │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                    Finder-Style File Browser                         │   │
│   │   File List | Grid View | Preview | Search                          │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Quick Start

### Laptop Setup

```bash
cd laptop
open BridgeMenuBar/BridgeMenuBar.xcodeproj
# Build and run in Xcode
```

### Mobile Setup

```bash
cd mobile
npm install
npx react-native start
# In another terminal:
npx react-native run-ios
```

## Documentation

- [Design Document](docs/DESIGN.md) - Full technical specification

## License

MIT
