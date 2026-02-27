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
## How to create own docker image:
17. Create a Dockerfile with the necessary **instructions** to build your image. For example:
```Dockerfile
# start from a base OS or another image
FROM ubuntu
# install dependencies
# RUN command is used to execute commands during the build process of the image. In this example, it updates the package list and installs curl in the image.
RUN apt-get update && apt-get install -y curl   
# copy files from local machine to the image
#It copies all files from the current directory (.) on the local machine to the /opt/source-code directory inside the image.
COPY . /opt/source-code 
expose 8080 # it will expose port 8080 from the container to the outside world, so that we can access the application running inside the container on that port.

#Entrypoint is used to specify the command that will be executed when a container is run from the image. In this example, it runs the script located at /opt/source-code/start.sh inside the container.
ENTRYPOINT ["/opt/source-code/start.sh"]

```
### Building the image using the Dockerfile:
18. Build the image using the Dockerfile:
```bash
docker build -t <image_name>:<tag> . # it will build the image using the Dockerfile in the current directory (.) and tag it with <image_name>:<tag>
#docker build the image layer by layer, it will execute each instruction in the Dockerfile and create a new layer for each instruction. If there is any change in the instruction, it will only rebuild that layer and the layers above it, which makes the build process faster.
```
### Environment Variables in Docker:
19. To set environment variables in a Docker container, you can use the `-e` flag with the `docker run` command. For example:
```bash
# Environment variables are key-value pairs that can be used to pass configuration information to the container at runtime. 
docker run -e DB_HOST=localhost -e DB_PORT=5432 <image_name>:<tag> # it will set the environment variables DB_HOST and DB_PORT inside the container
```
### Entrypoint vs CMD in Dockerfile:

| | `ENTRYPOINT` | `CMD` |
|---|---|---|
| **Purpose** | Fixed main command, always runs | Default arguments or default command |
| **Overridable?** | Only with `--entrypoint` flag | Yes, by passing args at `docker run` |
| **Used together** | Defines the executable | Provides default args to `ENTRYPOINT` |
| **Used alone** | Container always runs that command | Acts as the default command, fully replaceable |
Example:
```Dockerfile
FROM ubuntu
RUN apt-get update && apt-get install -y curl
COPY . /opt/source-code
ENTRYPOINT ["/opt/source-code/start.sh"]
# it will provide a default argument to the start.sh script
CMD ["--default-arg"]

```
In this example, when you run the container without providing any additional command-line arguments, it will execute the `start.sh` script with the default argument `--default-arg`. If you run the container with additional command-line arguments, for example:
```bash
docker run <image_name>:<tag> --custom-arg
```
In this case, the `start.sh` script will be executed with the custom argument `--custom-arg`, overriding the default argument specified in `CMD`. However, the `ENTRYPOINT` will still ensure that the `start.sh` script is executed as the main command of the container, regardless of the arguments provided when running the container.

### Working directory in Docker:
20. To set the working directory in a Docker container, you can use the `WORKDIR` instruction in the Dockerfile. For example:
```Dockerfile
FROM ubuntu
# WORKDIR /app creates /app if it doesn’t exist.
# it will set the working directory to /app inside the container (it is like cd /app in the terminal)
WORKDIR /app 

# it will copy all files from the current directory on the local machine to the current working directory (/app) inside the container
COPY . . 
```
21. Label is a key-value pair that can be added to Docker images, containers, or other Docker objects to provide metadata about the object. Labels can be used for various purposes, such as organizing and categorizing Docker objects, providing information about the image or container, or enabling automation and filtering based on specific criteria. Labels are defined in the Dockerfile using the `LABEL` instruction. For example:
```Dockerfile
FROM ubuntu
LABEL maintainer="John Doe"
```
22. ARG is used to define build-time variables in a Dockerfile. These variables can be passed during the build process and can be used to customize the image based on different build configurations. Unlike environment variables defined with `ENV`, which are available at runtime, `ARG` variables are only available during the build stage and cannot be accessed after the image is built. For example:
```Dockerfile
FROM ubuntu
ARG APP_VERSION=1.0
RUN echo "Building version $APP_VERSION of the application"
```
In this example, the `APP_VERSION` argument is defined with a default value of `1.0`. During the build process, you can override this value by passing a different value for the `APP_VERSION` argument using the `--build-arg` flag with the `docker build` command. For example:
```bash
docker build --build-arg APP_VERSION=2.0 -t my-app:2.0 .
```
23. link is a legacy feature in Docker that allows you to connect two containers together and enable communication between them. It creates a network connection between the linked containers, allowing them to communicate using their container names as hostnames.
```bash
docker run -d --name web nginx:latest #here web is the container name
docker run -d --name app --link web:web db:latest 
```
## Docker Compose:
- Docker Compose is a tool that allows you to define and manage multi-container Docker applications. It uses a YAML file to configure the application's services, networks, and volumes. With Docker Compose, you can easily start, stop, and manage multiple containers as a single application. For example, you can define a web application with a frontend service and a backend service in a `docker-compose.yml` file, and then use the `docker-compose up` command to start both services together. Docker Compose simplifies the process of orchestrating complex applications that require multiple containers to work together.
- File name docker-compose.yaml
```yaml
version: '3' # specify the version of the Docker Compose file format
# In version 3 a network is automatically created for the services defined in the file, and all services are connected to that network by default. This allows the services to communicate with each other using their service names as hostnames. For example, if you have a service named "web" and another service named "app", the "app" service can communicate with the "web" service using the hostname "web". 
services:
 web:
   image: nginx:latest # specify the Docker image to use for the web service
   ports:
     - "8080:80" # map port 8080 on the host to port 80 in the container
 app:
   image: my-app:latest # specify the Docker image to use for the app service
   environment:
     username: admin
     password: secret
       
   depends_on:
     - web # specify that the app service depends on the web service
   links: # don't need this field in version 3.
     - web # link the app service to the web service for communication
   
```
24. To start the application defined in the `docker-compose.yml` file, you can use the following command:
```bash
docker-compose up -d # it will start the application in detached mode (in the background) and return the container ids of the started services
```
