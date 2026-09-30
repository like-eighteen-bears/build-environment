ARG BASE_IMAGE=likeeighteenbears/build-environment:latest
FROM ${BASE_IMAGE}

# Images published before the development image removed the 'ubuntu' user still have it.
# It has UID/GID 1000, the most common host IDs, which would stop leb from taking them.
RUN if id ubuntu > /dev/null 2>&1; then userdel -r ubuntu; fi

# Match the host user so files written to the workspace are owned by them, and match
# the docker socket's group so leb can use it
ARG HOST_USER_ID
ARG HOST_GROUP_ID
ARG DOCKER_GROUP_ID
RUN /opt/leb/update_user_group_ids.sh "${HOST_USER_ID}" "${HOST_GROUP_ID}" "${DOCKER_GROUP_ID}"

USER $DEFAULT_USER
