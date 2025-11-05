FROM ubuntu:latest
LABEL authors="viktorkindrat"

ENTRYPOINT ["top", "-b"]