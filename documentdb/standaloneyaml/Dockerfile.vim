FROM ghcr.io/documentdb/documentdb/documentdb-local:latest

# Install vim
USER root
RUN apt-get update && apt-get install -y vim && rm -rf /var/lib/apt/lists/*

USER documentdb