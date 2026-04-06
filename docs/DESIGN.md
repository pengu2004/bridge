# Bridge - Mobile Terminal with Local-First Sync

## Overview

A system that provides terminal access to your files from any mobile device, with bidirectional sync between your laptop and a remote server.

Terminal as primary interface = simpler than building a file browser UI.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                           S3 BUCKET                              │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  s3://bridge-bucket/                                   │   │
│  │  ├── home/                                              │   │
│  │  │   └── {user_id}/                                    │   │
│  │  │       ├── documents/                                 │   │
│  │  │       ├── projects/                                  │   │
│  │  │       └── .ssh/                                      │   │
│  │  └── .manifest/                                         │   │
│  │      └── {user_id}.json                                 │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                               ▲
                               │ S3 SDK (direct API)
                               │
┌─────────────────────────────────────────────────────────────────┐
│                         AWS EC2 (t3.micro)                      │
│  ┌──────────────────────┐   ┌──────────────────────────────┐  │
│  │  WebSocket Server     │   │  PTY Process                 │  │
│  │  + S3 SDK             │◄──│  (bash shell)               │  │
│  │  (no s3fs, no redis)  │   │                              │  │
│  └──────────────────────┘   └──────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
         ▲
         │ WebSocket
         │
┌─────────────────────────────────────────────────────────────────┐
│                    React Native App                              │
│  ┌──────────────────┐   ┌──────────────────┐                   │
│  │  xterm.js        │   │  Local Cache     │                   │
│  │  (terminal)      │   │  (SQLite)        │                   │
│  └──────────────────┘   └──────────────────┘                   │
└─────────────────────────────────────────────────────────────────┘
```

## Why Terminal?

| File Browser | Terminal |
|--------------|----------|
| Custom directory listing UI | `ls` (already exists) |
| Custom file preview (images, docs, code) | `cat`, `vim` |
| Custom git UI | `git` |
| Custom search UI | `grep`, `find` |
| Custom editor | `vim`, `nano` |
| **Every feature = new component** | **Delegate to CLI tools** |

Terminal-as-primary = **simpler to build**.

## Tech Stack

### Backend (EC2)
- **Runtime**: Node.js 18+
- **WebSocket**: ws
- **PTY**: node-pty (spawns bash shells)
- **Storage**: AWS SDK v3 (S3)
- **Process Manager**: PM2
- **No Redis, No S3FS**

### Mobile App
- **Framework**: React Native
- **Terminal**: xterm.js (via WebView)
- **Local Storage**: SQLite (Dexie.js)
- **WebSocket**: Native API

### Laptop (Sync)
- **Tool**: rclone
- **No custom sync client needed**

### Infrastructure
- **Compute**: AWS EC2 t3.micro
- **Storage**: AWS S3
- **Auth**: JWT tokens

## How It Works

### 1. User connects from mobile app
```
Mobile App ──WebSocket──> EC2
                         │
                         ├── Authenticates (JWT)
                         └── Spawns PTY (bash shell)
```

### 2. User runs commands
```
User types "ls -la"
Mobile ──WS──> EC2 PTY
              │
              ├── PTY executes command
              ├── S3 SDK reads directory metadata (cached in memory)
              └── Output sent back via WebSocket
```

### 3. File operations work via S3 SDK
```javascript
// When command touches a file (cat, vim, etc.)
// Backend intercepts and uses S3 SDK

async function readFile(path) {
  const key = `home/${userId}/${path}`;
  const response = await s3.getObject({ Bucket: 'bridge-bucket', Key: key });
  return response.Body.transformToString();
}

async function writeFile(path, content) {
  const key = `home/${userId}/${path}`;
  await s3.putObject({ Bucket: 'bridge-bucket', Key: key, Body: content });
}

// Shell's cwd maps to S3 prefix
// /home/user/projects/  →  s3://bridge/home/{user}/projects/
```

### 4. Laptop sync via rclone
```bash
# One-time setup
rclone config
# Choose S3, enter credentials

# Sync commands
rclone sync ~/projects s3:bridge-bucket/home/{user}/projects/
```

## Backend Implementation

### S3 Service (Backend)

```javascript
// src/s3.js
const { S3Client, GetObjectCommand, PutObjectCommand, ListObjectsV2Command, DeleteObjectCommand } = require('@aws-sdk/client-s3');

const s3 = new S3Client({ region: 'us-east-1' });
const BUCKET = 'bridge-bucket';

class S3Service {
  constructor(userId) {
    this.userId = userId;
    this.prefix = `home/${userId}/`;
    this.cache = new Map(); // In-memory cache
  }

  async list(path = '') {
    const key = this.prefix + path;
    const command = new ListObjectsV2Command({
      Bucket: BUCKET,
      Prefix: key,
      Delimiter: '/'
    });
    
    const response = await s3.send(command);
    return {
      files: (response.Contents || []).map(obj => ({
        name: obj.Key.replace(key, '').replace(this.prefix + path, ''),
        size: obj.Size,
        modified: obj.LastModified
      })),
      directories: (response.CommonPrefixes || []).map(p => ({
        name: p.Prefix.replace(key, '').replace('/', '')
      }))
    };
  }

  async read(key) {
    if (this.cache.has(key)) {
      return this.cache.get(key);
    }
    
    const fullKey = this.prefix + key;
    const command = new GetObjectCommand({ Bucket: BUCKET, Key: fullKey });
    const response = await s3.send(command);
    const content = await response.Body.transformToString();
    
    this.cache.set(key, content);
    return content;
  }

  async write(key, content) {
    const fullKey = this.prefix + key;
    await s3.send(new PutObjectCommand({
      Bucket: BUCKET,
      Key: fullKey,
      Body: content
    }));
    this.cache.set(key, content);
  }
}

module.exports = S3Service;
```

### PTY Handler (Backend)

```javascript
// src/pty.js
const pty = require('node-pty');
const S3Service = require('./s3');

class PtyManager {
  constructor(ws, userId) {
    this.ws = ws;
    this.s3 = new S3Service(userId);
    this.cwd = `/home/${userId}`;
    
    this.pty = pty.spawn('bash', [], {
      name: 'xterm-256color',
      cols: 80,
      rows: 24,
      cwd: this.cwd,
      env: process.env
    });

    this.pty.onData(data => {
      ws.send(JSON.stringify({ type: 'output', data }));
    });

    this.pty.onExit(() => {
      ws.send(JSON.stringify({ type: 'exit' }));
    });
  }

  handleCommand(input) {
    // Intercept file commands
    const cmd = input.trim();
    
    if (cmd.startsWith('cat ')) {
      const file = cmd.slice(4);
      this.s3.read(file).then(content => {
        this.pty.write(content + '\r');
      });
      return;
    }

    if (cmd === 'ls' || cmd.startsWith('ls ')) {
      const path = cmd.slice(3) || '';
      this.s3.list(path).then(result => {
        const output = result.directories.map(d => d.name + '/').join('  ') + '\n' +
                       result.files.map(f => f.name).join('  ');
        this.pty.write(output + '\r');
      });
      return;
    }

    if (cmd.startsWith('echo ') && cmd.includes('>')) {
      const [content, file] = cmd.split('>').map(s => s.trim());
      const text = content.replace(/^echo /, '').replace(/"/g, '');
      this.s3.write(file, text).then(() => {
        this.pty.write('\r');
      });
      return;
    }

    // Pass through to shell
    this.pty.write(input);
  }

  resize(cols, rows) {
    this.pty.resize(cols, rows);
  }

  kill() {
    this.pty.kill();
  }
}

module.exports = PtyManager;
```

### WebSocket Server (Backend)

```javascript
// src/index.js
const WebSocket = require('ws');
const PtyManager = require('./pty');
const jwt = require('jsonwebtoken');

const wss = new WebSocket.Server({ port: 8080 });

const sessions = new Map(); // userId -> PtyManager

wss.on('connection', (ws, req) => {
  const token = req.headers.authorization?.replace('Bearer ', '');
  
  try {
    const { userId } = jwt.verify(token, process.env.JWT_SECRET);
    
    const pty = new PtyManager(ws, userId);
    sessions.set(userId, pty);

    ws.on('message', (msg) => {
      const { type, data, cols, rows } = JSON.parse(msg);
      
      if (type === 'input') {
        pty.handleCommand(data);
      }
      if (type === 'resize') {
        pty.resize(cols, rows);
      }
    });

    ws.on('close', () => {
      pty.kill();
      sessions.delete(userId);
    });

  } catch (err) {
    ws.close(4001, 'Unauthorized');
  }
});
```

## AWS Resources

### S3 Bucket Structure

```
s3://bridge-bucket/
├── home/
│   └── {user_id}/
│       ├── documents/
│       ├── projects/
│       │   ├── index.js
│       │   └── package.json
│       └── .ssh/
└── .manifest/
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

### EC2 Setup (Simplified)

```bash
# Install dependencies only
sudo apt update
sudo apt install -y nodejs npm

# No s3fs, no redis

# Deploy
git clone https://github.com/your-user/bridge.git
cd bridge/backend
npm install
pm2 start src/index.js
```

## Laptop Sync

```bash
# Install rclone
brew install rclone  # macOS
# or: curl https://rclone.org/install.sh | sudo bash

# Configure once
rclone config
# Choose: s3
# Provider: AWS
# Access Key: xxx
# Secret Key: xxx
# Region: us-east-1
# Name: bridge-s3

# Sync up (laptop → S3)
rclone sync ~/projects bridge-s3:bridge-bucket/home/{user}/projects/ -v

# Sync down (S3 → laptop)
rclone sync bridge-s3:bridge-bucket/home/{user}/projects/ ~/projects -v

# Or use rclone mount for live access (experimental)
rclone mount bridge-s3:bridge-bucket /mnt/bridge --vfs-cache-mode writes
```

## Security

### Authentication Flow

1. User enters credentials in mobile app
2. App sends to `/api/auth/login` on EC2
3. Server validates, returns JWT (24h expiry)
4. All WebSocket connections include JWT header
5. Server verifies JWT, extracts userId

### Security Considerations

- IAM role on EC2 (no credentials in code)
- JWT with short expiry
- Security groups: only port 8080 (WS) + 443 (HTTPS)
- No filesystem access (all via S3 SDK)

## Tradeoffs

### Advantages

1. **Simple backend**: No S3FS, no Redis, just Node.js + S3 SDK
2. **Cost-effective**: t3.micro + S3 at $0.023/GB
3. **Terminal simplicity**: Built-in CLI tools for all file operations
4. **Laptop sync**: rclone handles sync (battle-tested)

### Disadvantages

1. **No offline on mobile**: Always requires EC2 connection
2. **Latency**: Every file op hits S3 via EC2
3. **Shell complexity**: Intercepting commands is fragile
4. **Terminal UX**: Small screen, no keyboard on mobile

### Mitigations

| Issue | Solution |
|-------|----------|
| Latency | Cache recent file reads in memory |
| Offline | Skip for MVP (mobile always online anyway) |
| Shell intercept | Only intercept common commands (cat, ls), pass rest through |

## Cost Estimate

| Resource | Monthly Cost |
|----------|--------------|
| EC2 t3.micro | ~$5 (always on) or $0 (free tier) |
| S3 storage (50GB) | $1.15 |
| S3 requests | ~$0.50 |
| Data transfer | ~$1 |
| **Total** | **$7-8/month** |

## File Structure

```
bridge/
├── docs/
│   └── DESIGN.md
├── backend/
│   ├── src/
│   │   ├── index.js          # WebSocket server
│   │   ├── pty.js           # PTY + shell interception
│   │   ├── s3.js            # S3 SDK wrapper
│   │   └── auth.js          # JWT handling
│   ├── package.json
│   └── Dockerfile
├── mobile/
│   ├── src/
│   │   ├── App.tsx
│   │   ├── components/
│   │   │   └── Terminal.tsx
│   │   └── services/
│   │       └── websocket.ts
│   └── package.json
├── laptop/
│   └── sync.sh              # rclone wrapper script
└── README.md
```

## Getting Started

### Backend
```bash
cd backend
npm install
# Set AWS_REGION, JWT_SECRET env vars
pm2 start src/index.js
```

### Mobile
```bash
cd mobile
npm install
npm start
```

### Laptop
```bash
# Install rclone
brew install rclone

# Configure S3
rclone config

# Add to ~/.zshrc
alias bridge-sync="rclone sync ~/projects bridge-s3:bridge-bucket/home/your-user/projects/"
```

## Future Improvements

1. **Better shell integration**: Full PTY pass-through with S3FS-like interception
2. **Git integration**: Automatic git operations via S3
3. **Mobile caching**: SQLite on phone for offline file access
4. **Better terminal UX**: Larger touch targets, swipe gestures
