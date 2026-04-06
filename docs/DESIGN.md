# Bridge - Mobile Terminal with Local-First Sync

## Overview

A system that provides terminal access to your files from any mobile device, with bidirectional sync between your laptop and a remote server, using local storage on the device for performance.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                           S3 BUCKET                              │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  s3://my-sync-bucket/                                   │   │
│  │  ├── home/                                              │   │
│  │  │   └── ubuntu/                                        │   │
│  │  │       ├── documents/                                 │   │
│  │  │       ├── projects/                                  │   │
│  │  │       └── .ssh/                                      │   │
│  │  └── .config/                                           │   │
│  │      └── user-settings.json                             │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │ Delta sync
                              │
┌─────────────────────────────────────────────────────────────────┐
│                         AWS EC2 (t3.micro)                      │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────────┐    │
│  │  WebSocket   │   │  PTY Process │   │  Redis Cache    │    │
│  │  Server      │◄──│  (bash)      │   │  (dir listings) │    │
│  └──────────────┘   └──────────────┘   └──────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
         ▲
         │ WebSocket
         │
┌─────────────────────────────────────────────────────────────────┐
│                    React Native App                              │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────────┐    │
│  │  Local       │   │  SQLite/     │   │  Command        │    │
│  │  Terminal    │   │  Dexie.js    │   │  Queue          │    │
│  │  Emulator    │   │  (metadata)  │   │  (offline)      │    │
│  └──────────────┘   └──────────────┘   └──────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

## Tech Stack

### Backend (EC2)
- **Runtime**: Node.js 18+
- **WebSocket**: ws or socket.io
- **PTY**: node-pty (spawns real bash shells)
- **Session Management**: tmux/screen (persist across reconnects)
- **Cache**: Redis (directory listings)
- **Storage**: S3 via AWS SDK
- **Process Manager**: PM2

### Mobile App
- **Framework**: React Native
- **Terminal**: xterm.js (via WebView)
- **Local Storage**: SQLite (Dexie.js) for metadata cache
- **File Cache**: File system for recent file contents
- **HTTP Client**: Axios
- **WebSocket**: Native WebSocket API

### Infrastructure
- **Compute**: AWS EC2 t3.micro
- **Storage**: AWS S3
- **Auth**: JWT tokens
- **Networking**: Elastic IP + Security Groups

## Data Flow

### Sync Protocol

```javascript
// On connect
const sync = async () => {
  // 1. Get remote manifest (file hashes + modified dates)
  const remote = await s3.listWithHashes(bucket);
  
  // 2. Compare with local manifest
  const local = await db.getManifest();
  
  // 3. Compute delta
  const toDownload = remote.filter(r => 
    !local[r.path] || local[r.path].hash !== r.hash
  );
  
  const toUpload = local.filter(l =>
    !remote[l.path] || remote[l.path].hash !== l.hash
  );
  
  // 4. Apply delta (background)
  await Promise.all([
    downloadFiles(toDownload),
    uploadFiles(toUpload)
  ]);
  
  // 5. Update local manifest
  await db.updateManifest(remote);
};
```

### Offline Command Queue

```javascript
const queue = {
  add: (cmd) => db.pendingCommands.add(cmd),
  flush: async () => {
    while (cmd = await db.pendingCommands.shift()) {
      await execute(cmd);
      await sync();
    }
  }
};
```

### Terminal Flow (Optimized)

```
User types "ls projects/"
│
├─ Mobile: Query local SQLite → 5ms response
│          Shows cached directory listing
│
├─ Background: Check S3 for changes since last sync
│              Compare file hashes
│              Download only changed files
│
└─ UI: Subtle "syncing..." indicator, file counts
```

## Performance

### Optimized vs Unoptimized

| Operation | Optimized | Unoptimized |
|-----------|-----------|-------------|
| ls (100 files) | 5ms | 500ms |
| cat (small file) | 2ms | 300ms |
| ls again (same dir) | 1ms | 500ms |
| Edit file offline | Instant | N/A |

### Key Optimizations

1. **Local Terminal Echo**: Show characters immediately, don't wait for server
2. **SQLite Metadata Cache**: Directory listings stored locally
3. **File Content Cache**: Recently accessed files cached on device
4. **Delta Sync**: Only transfer changed files
5. **Redis on Server**: Cache S3 listings for faster directory access

## AWS Resources

### S3 Bucket Structure

```
s3://bridge-bucket/
├── home/
│   └── {user_id}/
│       ├── documents/
│       ├── projects/
│       └── .ssh/
└── .sync/
    └── manifests/
        └── {user_id}.json
```

### IAM Policy for EC2

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket"
    ],
    "Resource": [
      "arn:aws:s3:::bridge-bucket",
      "arn:aws:s3:::bridge-bucket/*"
    ]
  }]
}
```

### EC2 Setup

```bash
# Install dependencies
sudo apt update
sudo apt install -y nodejs npm redis-server s3fs tmux

# Mount S3 (fstab entry)
s3fs#bridge-bucket /mnt/s3 -o use_cache=/tmp/s3fs,_netdev,allow_other

# S3FS optimizations
s3fs bucket /mnt/s3 \
  -o use_cache=/tmp/s3fs \
  -o max_stat_cache_size=10000 \
  -o stat_cache_expire=900 \
  -o multipart_size=52 \
  -o parallel_count=10
```

## Security

### Authentication Flow

1. User enters credentials in mobile app
2. App sends credentials to EC2 via HTTPS
3. EC2 validates against stored hash (or Cognito)
4. Returns JWT token (expires in 24h)
5. All subsequent WebSocket connections include JWT
6. JWT verified on each connection

### Security Considerations

- S3 credentials on EC2 via IAM role (not hardcoded)
- Terminal sessions authenticated
- JWT tokens with short expiry
- Security groups restrict access to necessary ports only
- No filesystem-level encryption (relies on S3 encryption)

## Tradeoffs

### Advantages

1. **Cost-effective**: t3.micro ~$5-10/month + S3 at $0.023/GB
2. **Offline-capable**: Local cache allows work without connection
3. **Fast UI**: Local-first design feels instant
4. **Cross-platform**: Works from any device with browser/app
5. **Persistent storage**: S3 is always available

### Disadvantages

1. **S3FS latency**: 50-200ms per operation vs 0.1ms local
2. **Sync complexity**: Conflicts need resolution strategy
3. **Network dependency**: Still requires internet for sync
4. **EC2 maintenance**: Security patches, disk space management
5. **Terminal UX**: Mobile terminal is never as good as desktop

### User Experience Concerns

| Concern | Mitigation |
|---------|------------|
| EC2 boot time | Keep EC2 always on (~$5/mo) |
| Terminal lag | Local echo, optimistic updates |
| File sync conflicts | Last-write-wins default, git-style merge option |
| Connection drops | tmux persists sessions, auto-reconnect |
| S3FS hangs | Watchdog scripts, local cache fallback |

## Conflict Resolution

| Scenario | Resolution |
|----------|------------|
| Edit on phone, edit on laptop | Last-write-wins by default |
| Edit on phone, delete on laptop | Phone edit wins (restore from trash) |
| Edit both within seconds | Prompt user to choose |
| Advanced mode | Git-style conflict markers |

## Future Improvements

1. **Git integration**: Automatic commits, branches, merges
2. **Real-time collaboration**: Multiple users in same session
3. **Video streaming**: For GUI applications
4. **Lambda functions**: Serverless sync processing
5. **CloudFront CDN**: For faster file access globally

## Cost Estimate

| Resource | Monthly Cost |
|----------|--------------|
| EC2 t3.micro | $5-10 (free on new account) |
| S3 storage (50GB) | $1.15 |
| S3 transfer (10GB) | $0.90 |
| EIP (if always-on) | $3.60 |
| **Total** | **$10-15/month** |

## Getting Started

1. Create AWS account with t3.micro free tier
2. Create S3 bucket with appropriate IAM policy
3. Launch EC2 with IAM role for S3 access
4. Install Node.js, Redis, tmux on EC2
5. Deploy WebSocket server
6. Mount S3 bucket on EC2
7. Install React Native app
8. Configure connection to EC2 IP

## File Structure

```
bridge/
├── docs/
│   └── DESIGN.md
├── backend/
│   ├── src/
│   │   ├── index.js          # Entry point
│   │   ├── websocket.js      # WebSocket server
│   │   ├── pty.js            # PTY management
│   │   ├── sync.js           # S3 sync logic
│   │   └── auth.js           # JWT authentication
│   ├── package.json
│   └── Dockerfile
├── mobile/
│   ├── src/
│   │   ├── App.tsx
│   │   ├── components/
│   │   │   └── Terminal.tsx
│   │   ├── services/
│   │   │   ├── websocket.ts
│   │   │   └── sync.ts
│   │   └── store/
│   │       └── db.ts         # Dexie.js SQLite
│   └── package.json
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
└── README.md
```
