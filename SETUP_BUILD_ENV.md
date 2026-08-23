# Setting Up the Build Environment for AM01

The AM01 mining stack **must be built on Linux**. You have three options:

---

## Option 1: WSL (Windows Subsystem for Linux) — EASIEST

### Step 1: Install WSL on Windows

Open **PowerShell as Administrator** and run:

```powershell
wsl --install
# Restart your computer when prompted
```

This installs WSL 2 with Ubuntu by default.

### Step 2: Verify WSL

After restart:
```powershell
wsl --list --verbose
# Should show Ubuntu running on WSL 2
```

### Step 3: Enter WSL & Install Build Tools

```powershell
wsl
# Now you're in the Linux bash shell
```

Inside WSL, install build dependencies:

```bash
sudo apt-get update
sudo apt-get install -y build-essential libncurses-dev git wget bc unzip

# Verify
gcc --version
make --version
```

### Step 4: Access Your Repo in WSL

Your Windows `C:\Users\Colin\Documents\GitHub` is accessible in WSL as `/mnt/c/Users/Colin/Documents/GitHub`:

```bash
cd /mnt/c/Users/Colin/Documents/GitHub/am01
ls hardware/qmtech-kintex7/sw/

# Make the build script executable
chmod +x BUILD_AM01.sh

# Run it!
./BUILD_AM01.sh all
```

### Step 5: Clone Buildroot (if needed for full image)

```bash
cd /mnt/c/Users/Colin/Documents/GitHub
git clone https://git.buildroot.net/buildroot buildroot
cd buildroot
git checkout 2025.01
```

Then:
```bash
cd /mnt/c/Users/Colin/Documents/GitHub/am01
./BUILD_AM01.sh buildroot
```

---

## Option 2: VirtualBox/VMware with Linux VM

### Step 1: Create VM
- Download Ubuntu 22.04 LTS
- Create VM with ~30 GB disk, 8 GB RAM
- Allocate 4+ cores

### Step 2: Install Build Tools

Inside the VM:
```bash
sudo apt-get update
sudo apt-get install -y build-essential libncurses-dev git wget bc unzip

# Install development tools
sudo apt-get install -y vim curl openssh-server
```

### Step 3: Mount Shared Folder (VirtualBox)

In VirtualBox settings, add shared folder pointing to `C:\Users\Colin\Documents\GitHub`

In the VM:
```bash
mkdir -p ~/github
sudo mount -t vboxsf github ~/github
cd ~/github/am01
./BUILD_AM01.sh all
```

---

## Option 3: Remote Linux Machine / Cloud

If you have a Linux server or cloud instance:

```bash
# SSH into the machine
ssh user@your-linux-box

# Clone the repo
git clone https://github.com/colneech-dev/am01.git
cd am01

# Install tools
sudo apt-get update && sudo apt-get install -y build-essential libncurses-dev

# Build
chmod +x BUILD_AM01.sh
./BUILD_AM01.sh all

# Copy back to Windows
scp -r output/images/* user@windows-box:/c/Users/Colin/
```

---

## Quick Start (WSL)

If you just want to get started ASAP with WSL:

### Terminal 1: One-time Setup

```powershell
# PowerShell as Admin
wsl --install

# Wait for restart...

wsl

# Inside WSL:
sudo apt-get update && sudo apt-get install -y build-essential libncurses-dev git

cd /mnt/c/Users/Colin/Documents/GitHub/am01
chmod +x BUILD_AM01.sh
```

### Terminal 2: Run Build (3 cores, ~20 min)

```powershell
wsl
cd /mnt/c/Users/Colin/Documents/GitHub/am01
./BUILD_AM01.sh daemon
```

---

## What the Build Script Does

The `BUILD_AM01.sh` script:

1. **Verifies prerequisites** (gcc, make, git, odo-miner-cyclonev source)
2. **Builds binaries** (odo-miner, odo-webd, odo-ui)
3. **Uses 3 cores** by default (configurable via `BUILD_CORES=`)
4. **Takes ~3 min** for daemon, ~2 min for web server, ~3 min for UI

### Usage

```bash
# Interactive (choose what to build)
./BUILD_AM01.sh

# Build all binaries
./BUILD_AM01.sh all

# Build daemon only
./BUILD_AM01.sh daemon

# Build full Buildroot image
./BUILD_AM01.sh buildroot

# Install to a directory
./BUILD_AM01.sh install /mnt/rootfs
```

---

## Building the Full Buildroot Image

If you want the **complete CM4 rootfs** (recommended for deployment):

### Prerequisites

```bash
# Inside WSL or Linux
sudo apt-get install -y libncurses-dev unzip wget
git clone https://git.buildroot.net/buildroot ~/buildroot
cd ~/buildroot
git checkout 2025.01
```

### Build

```bash
cd /mnt/c/Users/Colin/Documents/GitHub/am01
BUILD_CORES=3 BUILDROOT_DIR=~/buildroot ./BUILD_AM01.sh buildroot
```

### Output

```bash
~/buildroot/output/images/
├── rootfs.tar.gz       # Root filesystem (to extract on SD card)
├── Image.gz            # Linux kernel
├── bcm2711-rpi-4-b.dtb # Device tree
└── ...
```

---

## Troubleshooting

### "gcc: command not found"

You're still in native Windows bash, not WSL. Fix:

```powershell
wsl
# Now you're in Linux
```

### "Permission denied: ./BUILD_AM01.sh"

Make it executable:

```bash
chmod +x BUILD_AM01.sh
./BUILD_AM01.sh
```

### "odo-miner-cyclonev not found"

The build script checks for `../../odo-miner-cyclonev` relative to the repo. Verify:

```bash
ls /mnt/c/Users/Colin/Documents/GitHub/odo-miner-cyclonev/hps/miner_pipe.c
```

If missing, clone it:

```bash
cd /mnt/c/Users/Colin/Documents/GitHub
git clone https://github.com/colneech-dev/odo-miner-cyclonev
```

### Build is slow

Increase cores:

```bash
BUILD_CORES=8 ./BUILD_AM01.sh all
```

(Adjust to your CPU count)

---

## Next Steps After Building

Once binaries are built:

1. **Flash SD card** with Buildroot image (or use rootfs.tar.gz)
2. **Boot CM4**
3. **Configure pool** in `/etc/default/odo-miner`
4. **Start mining** with `systemctl start odo-miner`

See `COMPLETE_STACK_SUMMARY.md` for detailed next steps.

---

## Questions?

- WSL issues: [WSL Docs](https://learn.microsoft.com/en-us/windows/wsl/install)
- Buildroot issues: [Buildroot Manual](https://buildroot.org/docs.html)
- AM01 specific: Check `FUTURE_WORK.md` and `COMPLETE_STACK_SUMMARY.md`

