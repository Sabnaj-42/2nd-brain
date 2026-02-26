## Docker
### Definition: 
Docker is an open-source platform that automates the deployment, scaling, and management of applications using containerization. Think of it as a way to package your application and all its dependencies (code, runtime, libraries, system tools) into a standardized unit called a container.

***Core Concepts:***

| Concept     | Description |
|-------------|-------------|
| Container   | A lightweight, standalone, executable package that includes everything needed to run a piece of software |
| Image       | A read-only template used to create containers (like a blueprint) |
| Dockerfile  | A text file with instructions to build a Docker image |
| Docker Hub  | A cloud-based registry service for sharing container images |

### Docker Commands: 
1. To show all running containers:
```bash
docker ps
```
2. To show all running and stopped containers:
```bash
docker ps -a
```
3. To stop a running container:
```bash
docker stop <container_id>
```
4. To remove a container:
```bash
docker rm <container_id>
```
5. To see available images:
```bash 
docker images
```
6. To remove an image:
```bash
docker rmi <image_id>  #delete all dependant containers to remove image
```
7. To pull an image from Docker Hub:
```bash
docker pull <image_name>:<tag>
```
8. To execute a command inside a running container:
```bash
docker exec  <container_id> cat /etc/hosts # it will show the content of /etc/hosts file inside the container
```
9. To see the details of a docker container:
```bash
docker inspect <container_id/name>
```
10. To see the logs of a container:
```bash
docker logs <container_id/name>
```
11. To run in detached mode:
```bash
docker run -d <image_name>:<tag> # it will run the container in background and return the container id
```
12. To start interactive terminal in the cntainer:
```bash
docker run -it <container_id/name> # it will start an interactive terminal session inside the container
```
13. To map a port from the local machine to the container:
```bash
docker run -p <host_port>:<container_port> <image_name>:<tag> # it will map the host_port on the local machine to the container_port inside the container
# Example: docker run -p 8080:80 nginx:latest # it will map port 8080 on the local machine to port 80 inside the container running nginx
# User can access the nginx server running inside the container by navigating to http://localhost:8080 in their web browser
# To connect from the outside of the local machine, user can use the IP address of the local machine instead of localhost, for example: 192.168.0.102:8080 (192.168.0.102 is wifi ip)
```
14. To start interactive terminal while running the conatiner:
```bash
docker run -it <image_name>:<tag> # it will start the container and open an interactive terminal session inside the container
```
15. To map volume from local machine to the container: (when the conatiner id deleted the data will be lost, to avoid that we can use volume mapping to persist the data)
```bash
docker run -v <host_directory>:<container_directory> <image_name>:<tag> # it will map the host_directory(my pc directory) on the local machine to the container_directory inside the container
# Example: docker run -v /home/user/data:/data nginx:latest # it will map the /home/user/data directory on the local machine to the /data directory inside the container running nginx  
```
16. To show the time continiously in the terminal:
```bash
docker run timer # it will show the time in the terminal every second
```