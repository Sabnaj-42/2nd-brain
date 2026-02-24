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
