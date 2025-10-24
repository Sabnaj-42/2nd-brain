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
26. 