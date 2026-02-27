## Docker

### Definition
Docker is an open-source platform that automates the deployment, scaling, and management of applications using containerization. Think of it as a way to package your application and all its dependencies (code, runtime, libraries, system tools) into a standardized unit called a container.

---

### Table of Contents
1. [Core Concepts](#core-concepts)
2. [Docker Commands](#docker-commands)
3. [How to Create Your Own Docker Image](#how-to-create-your-own-docker-image)
4. [Dockerfile Instructions](#dockerfile-instructions)
5. [Docker Compose](#docker-compose)

---

### Core Concepts

| Concept        | Description |
|----------------|-------------|
| Container      | A lightweight, standalone, executable package that includes everything needed to run a piece of software |
| Image          | A read-only template used to create containers (like a blueprint) |
| Dockerfile     | A text file with instructions to build a Docker image |
| Docker Hub     | A cloud-based registry service for sharing container images |
| Docker Compose | A tool to define and run multi-container apps using a `docker-compose.yml` YAML file |

---

### Docker Commands

#### Container Management
1. Show all **running** containers:
```bash
docker ps
```
2. Show **all** containers (running + stopped):
```bash
docker ps -a
```
3. Stop a running container:
```bash
docker stop <container_id>
```
4. Remove a container:
```bash
docker rm <container_id>
```
5. Run a container in **detached** (background) mode:
```bash
docker run -d <image_name>:<tag>
```
6. Start an **interactive terminal** in a new container:
```bash
docker run -it <image_name>:<tag>
```
7. Execute a command inside a **running** container:
```bash
docker exec -it <container_id> bash
# Example: read a file inside the container
docker exec <container_id> cat /etc/hosts
```
8. Inspect container details (IP, mounts, env vars, etc.):
```bash
docker inspect <container_id>
```
9. Follow container logs:
```bash
docker logs -f <container_id>
```
10. Map a host port to a container port:
```bash
docker run -p <host_port>:<container_port> <image_name>:<tag>
# Example: access nginx on http://localhost:8080
docker run -p 8080:80 nginx:latest
```
11. Mount a host directory as a volume (persists data beyond container lifecycle):
```bash
docker run -v <host_directory>:<container_directory> <image_name>:<tag>
# Example:
docker run -v /home/user/data:/data nginx:latest
```
12. Pass environment variables at runtime:
```bash
docker run -e DB_HOST=localhost -e DB_PORT=5432 <image_name>:<tag>
```

#### Image Management
13. List local images:
```bash
docker images
```
14. Pull an image from Docker Hub:
```bash
docker pull <image_name>:<tag>
```
15. Build an image from a Dockerfile:
```bash
docker build -t <image_name>:<tag> .
# Force a clean rebuild (ignore cache):
docker build --no-cache -t <image_name>:<tag> .
```
16. Tag an image (e.g. before pushing to a registry):
```bash
docker tag <image_id> <registry>/<image_name>:<tag>
```
17. Push an image to Docker Hub:
```bash
docker push <image_name>:<tag>
```
18. Remove an image (remove dependent containers first):
```bash
docker rmi <image_id>
```

#### Cleanup
19. Remove all stopped containers, unused images, networks, and build cache:
```bash
docker system prune -a
```

#### Networking
20. List networks:
```bash
docker network ls
```
21. Create a user-defined network (preferred over legacy `--link`):
```bash
docker network create <network_name>
docker run --network <network_name> <image_name>:<tag>
```

#### Volumes
22. List volumes:
```bash
docker volume ls
```
23. Create a named volume:
```bash
docker volume create <volume_name>
docker run -v <volume_name>:<container_directory> <image_name>:<tag>
```

---

### How to Create Your Own Docker Image

Create a `Dockerfile` with build instructions:
```Dockerfile
# Start from a base image
FROM ubuntu

# Install dependencies
RUN apt-get update && apt-get install -y curl

# Set the working directory (created if it doesn't exist — equivalent to cd /app)
WORKDIR /app

# Copy files from local machine into the image (. . means: local cwd → WORKDIR)
COPY . .

# Expose a port to the outside world
EXPOSE 8080

# Command that always runs when the container starts
ENTRYPOINT ["/app/start.sh"]

# Default arguments passed to ENTRYPOINT (overridable at docker run)
CMD ["--default-arg"]
```

---

### Dockerfile Instructions

#### ENTRYPOINT vs CMD

| | `ENTRYPOINT` | `CMD` |
|---|---|---|
| **Purpose** | Fixed main command, always runs | Default arguments or default command |
| **Overridable?** | Only with `--entrypoint` flag | Yes, by passing args at `docker run` |
| **Used together** | Defines the executable | Provides default args to `ENTRYPOINT` |
| **Used alone** | Container always runs that command | Acts as the default command, fully replaceable |

```bash
# CMD is overridden, ENTRYPOINT still runs:
docker run <image_name>:<tag> --custom-arg
```

#### ENV — Runtime environment variables
```Dockerfile
ENV APP_ENV=production
```

#### ARG — Build-time variables only (not available at runtime)
```Dockerfile
ARG APP_VERSION=1.0
RUN echo "Building version $APP_VERSION"
```
```bash
docker build --build-arg APP_VERSION=2.0 -t my-app:2.0 .
```

#### LABEL — Metadata key-value pairs
```Dockerfile
LABEL maintainer="John Doe" version="1.0"
```

#### .dockerignore
Exclude files from the build context (like `.gitignore`):
```
node_modules
.git
*.log
```

---

### Docker Compose

- Tool to define and run **multi-container** Docker apps via a `docker-compose.yml` YAML file. Manages services, networks, and volumes together. Services communicate using their **service name as hostname**.
- > **Note:** The `version:` key is deprecated in Compose v2+ and can be omitted.

```yaml
# docker-compose.yml
services:
  web:
    image: nginx:latest
    ports:
      - "8080:80"

  app:
    image: my-app:latest
    environment:
      username: admin
      password: secret
    depends_on:
      - web
```

#### Docker Compose Commands

| Command | Description |
|---------|-------------|
| `docker compose up -d` | Start all services in detached mode |
| `docker compose down` | Stop and remove containers, networks |
| `docker compose logs -f` | Follow logs for all services |
| `docker compose ps` | List running services |
| `docker compose build` | Rebuild service images |
| `docker compose exec <svc> bash` | Open a shell in a running service |

