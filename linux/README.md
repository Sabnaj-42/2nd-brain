# Linux Essentials — Notes

---

## Kernel + Distribution = Operating System

- Linux itself is not an operating system — it’s the **kernel**.
- The **kernel** is the core part of an operating system that communicates directly with your computer’s **hardware** (CPU, memory, disks, etc.) and manages resources.
- On its own, the Linux kernel isn’t usable — it requires additional software, tools, libraries, and a user interface.

**Analogy:**
- **Linux:** Brain (Kernel)
- **Linux Distribution:** Complete body (Full operating system) — e.g., Ubuntu, Fedora, CentOS, Manjaro, Red Hat, etc.

---

## Ubuntu

Ubuntu is a **Linux distribution** (a complete operating system built on top of the Linux kernel).  
It includes:
- The Linux kernel
- GNU tools and libraries
- Package manager (`apt`)
- Desktop environment (e.g., GNOME)
- User applications (Firefox, LibreOffice, etc.)

**Conclusion:** Ubuntu is one of many operating systems built using the Linux kernel.

---

## Linux Commands

### Command Types

| Type | Description | Examples |
|------|--------------|-----------|
| **Internal / Built-in** | Commands built into the shell itself | `echo`, `cd`, `pwd` |
| **External** | Binary programs or scripts found in system paths | `mv`, `cp`, `date`, `uptime` |

---

### Absolute vs Relative Directory

| Type | Description | Example |
|------|--------------|----------|
| **Absolute Path** | Starts from the root `/` | `/home/sabnaj/go/src/` |
| **Relative Path** | Starts from the current working directory | `go/src/2ndbrain` |

---

## Shell Commands

- Press **Tab** to auto-complete or show available arguments after a command.
- The **PATH variable** is an environment variable that tells the shell where to look for executable programs.

### Example:
When you type `kubectl`, the shell:
1. Checks each directory listed in your `$PATH` variable (in order).
2. Executes the first match it finds.
3. If not found, shows `command not found`.

---

### Common Shell Commands

| Command | Description |
|----------|--------------|
| `pwd` | Show present working directory |
| `ls` | List directory contents |
| `mkdir Asia` | Create a new directory named *Asia* |
| `mkdir Asia US` | Create multiple directories |
| `cd Asia` | Change to *Asia* directory |
| `mkdir India/Mumbai` | Try to create *Mumbai* (fails if *India* doesn’t exist) |
| `mkdir -p India/Mumbai` | Create parent *India* and child *Mumbai* |
| `cd ..` | Move to parent directory |
| `mv /home/michel/Europe /home/michel/Africa` | Move *Europe* into *Africa* |
| `mv Asia/India/Munbai Asia/India/Mumbai` | Rename *Munbai* → *Mumbai* |
| `cp Asia/India/Mumbai/city.txt Africa/Egypt/Cairo` | Copy *city.txt* to *Cairo* folder |
| `rm Europe/UK/London/Tottenham.txt` | Delete *Tottenham.txt* file |
| `cat name.txt` | Display file contents |
| `touch roll.txt` | Create empty file *roll.txt* |
| `ls -a` | Show all files (including hidden files `.`) |
| `whatis date` | Show short info about *date* command |
| `date --help` | Show available options for *date* command |
| `apropos echo` | Show all commands related to keyword *echo* |
| `alias dt=date` | Make `dt` act as `date` command |
| `history` | Show previously used commands |
| `echo $SHELL` | Display current shell |
| `env` | Show environment variables |
| `export roll=1907042` | Set an environment variable |
| `echo $PATH` | Show directories in `$PATH` |
| `which kubectl` | Show full path of an executable |
| `file go/` | Show file type info |
| `ls -ld go.mod` | Show file info (type + permissions) |

---

## System Boot and Systemd

| Command | Description |
|----------|--------------|
| `ls -l /sbin/init` | `/sbin/init` is the first process started by the Linux kernel (initializes the system). |
| `systemctl get-default` | Show the default boot target (runlevel). |
| `systemctl set-default graphical.target` | Set the system to boot into GUI (desktop) by default. |
| `systemctl set-default multi-user.target` | Set the system to boot into CLI (non-GUI) mode. |

---

## Linux Root Filesystem Hierarchy

```plaintext
/
├── bin/      → Essential user commands (ls, cp, mv, bash)
│
├── boot/     → Bootloader & kernel files (vmlinuz, initrd.img, grub/)
│
├── dev/      → Device files (sda, sda1, null, tty)
│
├── etc/      → System configuration (passwd, hostname, fstab, ssh/)
│
├── home/     → User home directories (alice/, bob/)
│
├── lib/      → Shared libraries for binaries (libc.so.6, systemd/)
│
├── media/    → Mount points for removable media (usb/)
│
├── mnt/      → Temporary mount point for admins (backup/)
│
├── opt/      → Optional/add-on software (google/chrome/)
│
├── tmp/      → Temporary files (auto-cleared on reboot)
│
├── usr/      → User-installed programs & shared resources
│   ├── bin/      → Non-essential user commands
│   ├── lib/      → Libraries for user apps
│   ├── share/    → Shared docs/icons
│   └── local/    → Locally installed software
│
└── var/      → Variable data (changes often)
    ├── log/     → Logs
    ├── lib/     → App data
    ├── spool/   → Print/mail queues
    └── cache/   → Cached data
```

## Package Managers
A package manager in Linux is a tool (both command-line and backend system) that:
- installs, updates, configures, and removes software packages
- resolves dependencies automatically (installs required libraries or tools)
- keeps a local database of installed software
- connects to online repositories to fetch software

Common package managers by Linux Distribution:
```
| Distribution               | Package Manager      | Command Examples           |
| -------------------------- | -------------------- | -------------------------- |
| **Ubuntu / Debian**        | `apt` or `dpkg`      | `sudo apt install vim`     |
| **Fedora / RHEL / CentOS** | `dnf` or older `yum` | `sudo dnf install vim`     |
| **openSUSE**               | `zypper`             | `sudo zypper install vim`  |
| **Arch Linux / Manjaro**   | `pacman`             | `sudo pacman -S vim`       |
| **Alpine Linux**           | `apk`                | `sudo apk add vim`         |
| **Void Linux**             | `xbps-install`       | `sudo xbps-install -S vim` |
| **Gentoo**                 | `emerge`             | `sudo emerge vim`          |

```

---

## Package Managers

A **package manager** in Linux is a tool (both command-line and backend system) that:

- Installs, updates, configures, and removes software packages
- Resolves dependencies automatically (installs required libraries or tools)
- Keeps a local database of installed software
- Connects to online repositories to fetch software

### Common Package Managers by Linux Distribution

| Distribution               | Package Manager      | Example Command           |
| -------------------------- | -------------------- | -------------------------- |
| **Ubuntu / Debian**        | `apt`, `dpkg`        | `sudo apt install vim`     |
| **Fedora / RHEL / CentOS** | `dnf` (or `yum`)     | `sudo dnf install vim`     |
| **openSUSE**               | `zypper`             | `sudo zypper install vim`  |
| **Arch Linux / Manjaro**   | `pacman`             | `sudo pacman -S vim`       |
| **Alpine Linux**           | `apk`                | `sudo apk add vim`         |
| **Void Linux**             | `xbps-install`       | `sudo xbps-install -S vim` |
| **Gentoo**                 | `emerge`             | `sudo emerge vim`          |

---

### `dpkg` (Debian Package Manager)

| Command | Description |
|----------|-------------|
| `dpkg -i telnet.deb` | Install the package file `telnet.deb` |
| `dpkg -r telnet` | Remove the installed `telnet` package |
| `dpkg -l telnet` | List all installed packages related to `telnet` |
| `dpkg -s telnet` | Show detailed status of the `telnet` package |
| `dpkg -p <path>` | Show package details for the specified file |

---

### `apt` (Advanced Package Tool)

| Command | Description |
|----------|-------------|
| `sudo apt update` | Refresh local package list from repositories |
| `sudo apt upgrade` | Install available updates |
| `sudo apt install telnet` | Install the `telnet` package |
| `sudo apt remove telnet` | Remove the `telnet` package |
| `apt search telnet` | Search for `telnet` in repositories |

**Tip:**
- `apt update` → refreshes the catalog (like checking product prices)
- `apt upgrade` → installs updated packages (like actually buying the items)

---

## File-Related Commands

| Command | Description |
|----------|-------------|
| `du -sk test.img` | Show the size of a file/directory in KB |
| `du -sh test.go` | Show the size in human-readable format (MB, GB, etc.) |
| `ls -lh test.go` | Display file size and details |
| `tar -cf test.tar file1 file2 file3` | Create a tar archive (no compression) |
| `tar -tf test.tar` | List the contents of `test.tar` |
| `tar -xf test.tar` | Extract the contents of `test.tar` |
| `bzip2 test.img` | Compress `test.img` using bzip2 |
| `bunzip2 test.img.bz2` | Decompress bzip2 archive |
| `gzip test1.img` | Compress using gzip |
| `gunzip test1.img.gz` | Decompress gzip archive |
| `xz test2.img` | Compress using xz |
| `unxz test2.img.xz` | Decompress xz archive |
| `zcat` / `bzcat` / `xzcat` | View compressed files without extracting |

---

## Searching Files and Directories

| Command | Description |
|----------|-------------|
| `find /home/sabnaj -name city.txt` | Search recursively for file `city.txt` |
| `grep second sample.txt` | Search for “second” in `sample.txt` (case-sensitive) |
| `grep -i second sample.txt` | Case-insensitive search |
| `history | grep kubectl` | Search command history for “kubectl” |
| `grep -r "third line" /home/sabnaj` | Recursive search in directory |
| `grep -v "printed" sample.txt` | Show lines that do **not** contain “printed” |
| `grep -w exam example.txt` | Match only the whole word “exam” |

---

## vim text editor (updated version of vi editor)
**vim sabnaj.txt** // open file sabnaj.txt(if doesn't exist create a new file in the current directory) in the vim editor<br>

It has three modes: command mode, insert mode, last line. Command mode is the default mode.
<br>Type lowercase i to switch insert mode from command mode.
<br> press "Esc" key to get back into command mode.
<br> press ":" to go into last line mode. 

### Command Mode (Press `Esc` to enter)

| Command | Description |
|---------|-------------|
| `yy` | Copy the line where the cursor is placed |
| `p` | Paste the copied text below the current line |
| `x` | Delete the character under the cursor |
| `dd` | Delete the current line |
| `d3d` | Delete the next 3 lines from the cursor position |
| `u` | Undo the last change |
| `r` | Redo the last undone change |

### Last Line Mode (Press `:` to enter)

| Command | Description |
|---------|-------------|
| `:w` | Save the file |
| `:q` | Quit the file |
| `:wq` | Save and quit the file |
| `:q!` | Quit without saving changes |

---

## Linux Networking

| Command | Description |
|---------|-------------|
| `ping 192.168.1.11` | Check network connectivity between your computer and another device |
| `curl https://google.com` | Fetch or send data over the internet (HTTP/HTTPS/FTP) and display response in terminal |
| `dig www.google.com` | Show which DNS server was used and the IP returned |
| `nslookup www.google.com` | Alternative to `dig` for DNS lookup |
| `traceroute 192.168.1.2` | Trace the path packets take to a destination host/IP |

---

### Hostname

A hostname is a unique name assigned to a device (computer, server, or VM) on a network. It helps humans and systems identify machines more easily than using IP addresses.

| Command | Description |
|---------|-------------|
| `hostname` | Display the current system's hostname |

**Configuration Files:**
- `/etc/hostname` → Contains the hostname string
- `/etc/hosts` → Maps hostname to IP addresses

**Example `/etc/hosts`:**
```
127.0.0.1   localhost
127.0.1.1   my-computer
```
### DNS (Domain Name System)
DNS translates human-readable domain names (like www.google.com) into IP addresses (like 142.250.190.4) that computers use to communicate.
<br>**Lookup flow that happens when a Linux system needs to resolve a somain name:** <br>
- When we run a command like "ping www.google.com or open a website in a browser, the application ask the C library to resolve the domain name to an IP address
- Linux :
    - Check local files (like /etc/hosts)
    - If not found, query DNS servers <br>
  We can change the order of IP query by editing /etc/nsswitch.conf  "hosts" field files and dns order. <br>
  So Linux first looks for the name in /etc/hosts. If the domain matches here, DNS lookup stops
- If the name is not found in the /etc/hosts, Linux checks the DNS servers listed in:
 ```
/etc/resolv.conf
```
example:
```
nameserver 8.8.8.8 // content of /etc/resolv.conf
nameserver 1.1.1.1
```
- Linux will query these DNS services in order until one responds. It returns the IP address back to the system when it found one
- If the domain name is not found it return "Temporary failure in name resolution"

## Security and File Permissions

Linux provides commands to manage users, groups, and file permissions. Here are essential commands:

### User and System Information

| Command | Description |
|---------|-------------|
| `cat /etc/passwd` | Contains information about all user accounts on the system |
| `id` | Display user and group identity information |
| `last` | Show a list of the most recent user logins on the system |
| `su -` | Switch to another user with a full login shell (requires target user password) |
| `su -c "whoami"` | Temporarily switch to another user (default root), run a command (`whoami`) and return to current session |
| `cat /etc/sudoers` | Contains configuration defining which users/groups can run commands with `sudo` |
| `sudo visudo` | Edit `/etc/sudoers` safely |
| `cat /etc/shadow` | Securely stores user password hashes and account policies |
| `cat /etc/group` | Lists all groups, their GIDs, and member users |

---

### Creating Users and Managing Passwords

| Command | Description |
|---------|-------------|
| `useradd mmm` | Add a new user `mmm`:<br>- Entry added in `/etc/passwd`<br>- Group `mmm` added in `/etc/group`<br>- Home directory `/home/mmm` created if `-m` option used<br>- Default shell set (usually `/bin/bash`)<br>- `/etc/shadow` updated with empty password |
| `passwd mmm` | Set a password for user `mmm` |
| `passwd` | Change password for the current logged-in user |
| `su - mmm` | Switch to user `mmm` using their password |
| `userdel -r mmm` | Delete user `mmm` and remove home directory, mail, and files (`-r` flag) |

---

### Group Management

| Command | Description |
|---------|-------------|
| `groupadd developer` | Create a new group named `developer` with automatically assigned GID |
| `groupadd -g 1011 developer` | Create a group `developer` with specific GID `1011` |
| `groupdel developer` | Delete the group `developer` from the system |


## File Permissions

Linux file permissions control access for owner, group, and others.

| Command | Description |
|---------|-------------|
| `ls -l text.sh` | Show file permission details for owner (u), group (g), and others (o) in the format `rwxrwxrwx` |
| `chmod u+rwx test-file` | Provide full access to the owner |
| `chmod ugo+r-x test-file` | Provide read access to owner, group, others; remove execute permission |
| `chmod o-rwx test-file` | Remove all access for others |
| `chmod u+rwx,g+r-x,o-rwx test-file` | Full access for owner, read and remove execute for group, no access for others |
| `chmod 750 test-file` | Full access for owner, read & execute for group, no access for others |
| `chown mmm:developer test-file` | Change owner to `mmm` and group to `developer` |
| `chown mmm test-file` | Change owner to `mmm`, keep group unchanged |
| `chown :android test-file` | Change group to `android`, owner unchanged |

---
## SSH(secure shell) and SCP (secure copy protocol)
**SSH-->** it’s a protocol and command-line tool that lets you securely log into and control a remote Linux machine over a network.
100. ssh devop01 // connect to a remote system named devop01 using SSH (Secure Shell). need to provide remote systems' username and password

**Set up for passwordless SSH login:** suppose, we want to connect to the remote system "ssh alice@devop01", here alice is the user and devop01 is the system.<br>
- generate an ssh key pair (on your local machine)
  ```
  ssh-keygen #it generate private and public key. private key will be stored in ~/.ssh.id_rsa and public key will be stored in ~/.ssh/id_rsa.pub 
  ```
- copy the public key to the remote system
    ```
  ssh-copy-id alice@devop01
  #It copies your public key (id_rsa.pub) to the remote system.
  #Stores it in /home/alice/.ssh/authorized_keys on devop01.
  #You’ll be prompted for alice’s password one last time.
  ```
- test passwordless login
**SCP-->** 
101. scp /home/bob/caleston-code.tar.gz devapp01:/home/bob //securely copy a file from your local system to a remote system using SCP. need to provide remote user password

## Cronjob
a cron job is a scheduled task that runs automatically at specific times or intervals — managed by the cron daemon (crond). Each user (including root) can have their own crontab (cron table) that lists commands to be executed on a schedule. <br>

102. crontab -e // opens crontab file in the default test editor (like vi or nano). we can then add, modify or remove scheduled tasks.

<br>**Example of crontab Entry:**
```
# ┌───────────── minute (0 - 59)
# │ ┌───────────── hour (0 - 23)
# │ │ ┌───────────── day of month (1 - 31)
# │ │ │ ┌───────────── month (1 - 12)
# │ │ │ │ ┌───────────── day of week (0 - 6) (Sunday=0 or 7)
# │ │ │ │ │
# * * * * *  command_to_run
eg:
0 2 * * * /home/user/backup.sh  // run a script every day at 2 AM
*/5 * * * * /home/user/backup.sh //run a srcipt in every 5 minutes

```

## systemd

`systemd` is the init system and service manager used by most modern Linux distributions (like Ubuntu, Debian, CentOS, Fedora, RHEL).  
It is responsible for booting the system and managing all system services and processes after boot.

---

### Key Components of systemd

| Component | Description |
|-----------|-------------|
| `systemd` | Runs as PID 1. Initializes the system and manages services |
| Units | Resources that systemd manages. Examples: <br>• `.service` → background service <br>• `.socket` → network/socket activation <br>• `.mount` → filesystem mounts <br>• `.target` → system states (like `multi-user.target`) |
| `systemctl` | Command-line tool to control systemd (start/stop/enable services, check status, reboot, etc.) |
| `journald` | systemd’s logging service for system and service logs |

---

### System Boot Flow with systemd

1. BIOS/UEFI → bootloader (GRUB) → kernel
2. Kernel starts → systemd (PID 1)
3. systemd reads its configuration → determines default target (like `multi-user.target` for normal boot)
4. systemd starts all required units (services, mounts, timers) in the proper order
5. System is fully up → services keep running under systemd supervision


### run a project automatically on boot as a systemd service
1. let's assume our project runs with /opt/book-server/start.sh
2. create systemd service file
     ```bash
    sudo nano /etc/systemd/system/book-server.service
    ```
3. add the following content in the book-server.service file
    ```
    [Unit]
    Description=Project book-server Application Service
    After=network.target
    
    [Service]
    Type=simple
    User=sabnaj
    WorkingDirectory=/opt/book-server   #project is located here
    ExecStart=/opt/book-server/start.sh
    Restart=on-failure
    Environment="ENV=production"
    
    [Install]
    WantedBy=multi-user.target
    
     ```
4. Reload systemd to recognize our new service
    ```bash
    sudo systemctl daemon-reload
    ```
5. Start, test our service manually
     ```bash
    sudo systemctl start book-server.service  #start service manually 
    sudo systemctl status book-server.service  #check if it's runnig
    journalctl -u book-server.service -f  #view logs (if any output)
    
    ```
6. Enable it to start automatically boot
     ```bash
    sudo systemctl enable book-server.service
    ```
### systemctl Command for Service Management

`systemctl` is the primary command-line tool to manage systemd services on modern Linux distributions.

| Command | Description |
|---------|-------------|
| `systemctl start book-server.service` | Start the service immediately |
| `systemctl stop book-server.service` | Stop the service immediately |
| `systemctl restart book-server.service` | Stop and then start the service again (useful after code/config changes) |
| `systemctl reload book-server.service` | Reload the service configuration without stopping it (if supported) |
| `systemctl enable book-server.service` | Enable the service to start automatically at boot |
| `systemctl disable book-server.service` | Disable the service from starting automatically at boot |
| `systemctl status book-server.service` | Show the current status of the service — active, inactive, or failed, along with recent logs and process details |

## Storage in Linux
### Disk partition
- disk partitioning means dividing a physical hard drive (or SSD) into smaller, logical sections called partitions — each of which can be used to store data, install operating systems, or manage filesystems separately.
- Each partition  has its own filesystem and can be mounted to a directory (like /, /home, /boot, etc).
- Common partition types:
     ```
    Partition	Purpose
    / (root)	Contains the core system files (mandatory)
    /boot	Contains bootloader and kernel files
    /home	Stores user files and settings
    /var	Logs, databases, and variable data
    swap	Used as virtual memory when RAM is full
    ```
## Disk Partitioning and Filesystem Commands

| Command | Description |
|---------|-------------|
| `lsblk` | Lists all block devices and their mount points |
| `fdisk /dev/sdX` | CLI tool for partitioning MBR disks |
| `gdisk /dev/sdX` | CLI tool for partitioning GPT disks |
| `parted /dev/sdX` | Flexible partitioning tool supporting both MBR and GPT |
| `lsblk -f` | Shows filesystem types, UUIDs, and mount points |
| `blkid` | Lists block devices with UUID and filesystem information |
| `df -h` | Displays disk space usage for all mounted filesystems in human-readable format |
| `mkfs.ext4 /dev/sdXn` | Creates an ext4 filesystem on a partition <br>**Note:** Replace `/dev/sdXn` with your actual partition, e.g., `/dev/sda1` |


### Example workflow: Create and Mount a Partition
```bash
# Step 1: List all disks
lsblk

# Step 2: Start partitioning the disk
sudo fdisk /dev/sda

# Inside fdisk:
#   n → new partition
#   p → primary
#   1 → partition number
#   <Enter> for default first and last sector
#   w → write changes and exit

# Step 3: Create a filesystem
sudo mkfs.ext4 /dev/sda1

# Step 4: Create a mount point
sudo mkdir /mnt/data

# Step 5: Mount the partition
sudo mount /dev/sda1 /mnt/data

# Step 6: (Optional) Add to /etc/fstab for auto-mount at boot

```
**Viewing partition information:**

```bash
sudo fdisk -l      # Detailed partition info
lsblk -f           # Filesystem and mount details
df -h              # Disk usage

```