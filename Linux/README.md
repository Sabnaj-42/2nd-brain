## Kernel+distribution=operating system
- Linux itself is not an operating system — it’s the kernel.
- The kernel is the core part of an operating system that talks directly to your computer’s hardware (CPU, memory, disks, etc.) and manages resources.
- On its own, the Linux kernel isn’t usable — you need additional software, tools, libraries, and a user interface.
<br>***Linux:*** brain(kernel)
<br>***Linux Distribution:*** complete body(full operating system). eg: Ubuntu, Fedora, CentOS, Manjaro, Red Hat etc

### Ubuntu:
Ubuntu is a Linux distribution (a complete operating system built on top of the Linux kernel).
It includes:
- the Linux kernel
- GNU tools and libraries
- package manager (apt)
- desktop environment (like GNOME)
- other software (Firefox, LibreOffice, etc.
So Ubuntu is one of many operating systems built using the Linux Kernel


## Linux Command
Two types of command:
1. Internal or built-in commands: echo, cd, pwd e.t.c
2. External command: They are binary program or scripts (mv, date, uptime, cp e.t.c)

Absolute and relative directory: Absolute directory start from the root where relative directory start from the present working directory. <br>
absolute: /home/sabnaj/go/src/
Relative: go/src/2ndbrain

### Shell command
Press Tab key to see the available arguments after a command.<br>
***Path Variable:"*** is an environment variable that tells shell where to look for executable programs when a command is typed. 
- When we type "kubectl" the shell doesn't instantly know what kubectl is.
- So it checks a list of directories defined in your PATH variable — in order — until it finds an executable file named kubectl.
- If it doesn't find it in any of those directories, it will show "command not found"

1. pwd // present directory
2. ls // list contents of present directory
3. mkdir Asia // make a new directory named "Asia"
4. mkdir Asia US // make multiple directory
5. cd Asia //change directory to Asia
6. mkdir India/Mumbai  // create directory Mumbai without having going inside the directory India
7. mkdir -p India/Mumbai  // create the parent directory India then create directory Mumbai under it
8. cd .. // take to the parent directory of present directory
9. mv /home/michel/Europe /home/michel/Africa // move the directory Europe into Africa
10. mv Asia/India/Munbai Asia/India/Mumbai //change the directory name Munbai to Mumbai
11. cp Asia/India/Mumbai/city.txt Africa/Egypt/Cairo // cp the file city.txt to the folder Cairo
12. rm Europe/Uk/London/Tottenham.txt // remove the file tottenham.txt
13. cat name.txt //show the context of the file name.txt
14. touch roll.txt // create an empty file name roll.txt
15. ls -a // show the hidden file. startin with '.'. single 
16. whatis date // provides details about the "date" command
17. date --help // provide options of date command
18. apropos echo // show all command within the system that contain "echo" keyword
19. alias dt=date // after that in each command dt will be interpreted as date
20. history // show the previous command history
21. echo $SHELL //print the value of SHELL variable
22. env // show the values of environment variable (user informations)
23. export roll=1907042 //set environment variables and make them available to child processes of shell
24. echo $PATH // show all path variable vlues
25. which kubectl // show the full path of executable kubectl file (from $PATH variable)
26. file go/   //show the type of go/ file. is it a directory or what kind of file it is
27. ls -ld go.mod // first character indicate which type of file it is

### System Boot
28. ls -l /sbin/init   // /sbin/init is the first process started by the Linux kernel during boot — it initializes the system.
29. systemctl get-default // used on Linux systems with systemd to show the default boot target — that is, what mode or "runlevel" your system boots into by default.
30. systemctl set-default graphical.target // set the default target graphical. it also can be multi-user.target etc. System will automatically boot into the GUI (desktop environment) on startup.

### Linux root filesystem
``` 
/
├── bin/                 → Essential user commands
│   ├── ls
│   ├── cp
│   ├── mv
│   └── bash
│
├── boot/                → Bootloader and kernel files
│   ├── vmlinuz-6.5.0
│   ├── initrd.img-6.5.0
│   └── grub/
│
├── dev/                 → Device files
│   ├── sda     (Hard disk)
│   ├── sda1    (Partition)
│   ├── null
│   └── tty
│
├── etc/                 → System configuration files
│   ├── passwd
│   ├── hostname
│   ├── fstab
│   └── ssh/
│
├── home/                → User home directories
│   ├── alice/
│   └── bob/
│
├── lib/                 → Essential shared libraries
│   ├── libc.so.6
│   └── systemd/
│
├── media/               → Removable media mount points
│   └── usb/
│
├── mnt/                 → Temporary mount point for admin use
│   └── backup/
│
├── opt/                 → Optional add-on applications
│   └── google/
│       └── chrome/
│
├── tmp/                 → Temporary files (auto-cleared on reboot)
│   └── temp1234.tmp
│
├── usr/                 → User-installed programs and resources
│   ├── bin/     → Non-essential user commands
│   ├── lib/     → Libraries for user programs
│   ├── share/   → Shared data, docs, icons
│   └── local/   → Locally installed software
│
└── var/                 → Variable data (changes frequently)
    ├── log/     → Log files
    ├── lib/     → Application data
    ├── spool/   → Print/mail queues
    └── cache/   → Cached data


```
### Package Managers
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

### dpkg (debian package manager)
31. dpkg -i telnet.deb // to install telnet
32. dpkg -r telnet.deb // to uninstall telnet
33. dpkg -l telnet // to list the package installed with telnet
34. dpkg -s telnet // to check the status of the package
35. dpkg -p <path to file> // to show the details of the package

### apt (higher level package manager of debian - advanced package manager)
32. sudo apt update //refresh package list
33. sudo apt upgrade // install available updates
- apt update → refreshes the catalog with the latest prices and products.
- apt upgrade → actually buys (downloads and installs) the updated items.
34. apt install telnet // to install telnet package
35. apt remove telnet // to remove telnet package
36. apt search telnet // used to look for the package telnet in a repository

### File related command
37. du -sk test.img //show the size of a file/directory in kB
38. du -sh test.go //show the size of a file/directory in MB
39. ls -lh test.go //show the size and details of file/directory
40. tar -cf test.tar file1 file2 file3 // Creates a tar archive named test.tar that contains file1, file2, and file3, without compression. -c --> create a new tar file. -f --> name it test.tar
41. tar -tf test.tar // show the contexts of test.tar archive file
42. tar -xf test.tar // extract the contexts from the test.tar tar file
43. bzip2 test.img // compress the test.img file into zip file
44. bunzip test.img.bz2 // unzip the zip file
45. gzip test1.img //compress test1.img into zip file
46. gunzip test1.img.gz //unzip the zip file
47. xz test2.img //compress the test2.img file into 
48. unxz test2.img // unzip the zip file
49. zcat/ bzcat/ xzcat // if we zip our file using these commands we can't unzip them

### Searching files and directories
50. find /home/sabnaj -name city.txt // Searches recursively inside /home/sabnaj for any file whose name is exactly city.txt, and prints the full path if found.
51. grep second sample.txt // search the word "second" in sample.txt file. grep command case sensitive
52. grep -i second sample.txt // -i flag make grep command case insensitive
53. history | grep kubectl // find the word "kubectl" in the output of history command
54. grep -r "third line" /home/sabnaj //search the word "third line" recursively in the /home/sabnaj directory
55. grep -v "printed" sample.txt //print all the line which doesn't contain printed
56. grep -w exam example.txt // print those line which contain exam "exam" word. not only pattern of exam

### vim text editor (updated version of vi editor)
**vim sabnaj.txt** // open file sabnaj.txt(if doesn't exist create a new file in the current directory) in the vim editor<br>

It has three modes: command mode, insert mode, last line. Command mode is the default mode.
<br>Type lowercase i to switch insert mode from command mode.
<br> press "Esc" key to get back into command mode.
<br> press ":" to go into last line mode. 

#### command mode (press 'Esc' key to turn into command line mode)
57. 'y y' -> copy the line in which the cursor is placed
58. 'p' -> paste the copied text in the line below the current cursor place
59. 'x' -> delete the selected character
60. 'd d' -> delete the line where cursor is placed
61. 'd 3 d' -> delete the next 3 lines from where the cursor is placed
62. 'u' -> undo the last change
63. 'r' -> redo the last change

#### last line mode ( press ':' to turn into last line mode)
64. ':w' -> save the file
65. ':q' -> quit the file
66. ':wq' -> save and quit the file
67. ':q!' -> quit without confirmation

### Linux networking
68. ping 192.168.1.11 //check network connectivity between your computer and another device with the IP address 192.168.1.11.
69. curl https://google.com // curl fetch or send data over the internet using various protocols (like HTTP, HTTPS, FTP, etc.). This command sends an HTTP GET request to https://example.com and displays the response (HTML or other data) in the terminal.
70. dig www.google.com // show which DNS server was used and what IP was returned
71. nslookup www.google.com // same as command 70

**Hostname:** 
- A hostname is the unique name assigned to a device (computer, server, or VM) on a network.
- It helps humans and systems identify machines more easily than using IP addresses.
72. hostname // shows the current system's hostname
 
- /etc/hostname → contains the hostname string
- /etc/hosts → maps hostname to IP, e.g.:
```
127.0.0.1   localhost
127.0.1.1   my-computer
```
#### DNS (Domain Name System)
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


