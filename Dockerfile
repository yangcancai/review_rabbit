FROM centos:7
WORKDIR /app
RUN yum install -y wget && \
    yum install -y https://packages.endpoint.com/rhel/7/os/x86_64/endpoint-repo-1.7-1.x86_64.rpm && \
  yum install -y git && \
 yum install -y epel-release && \
 yum install -y  build-essential openssl openssl-devel unixODBC unixODBC-devel  make gcc gcc-c++ kernel-devel m4 ncurses-devel tk tc xz && \
 yum install -y unixODBC  unixODBC-devel wxBase  wxGTK SDL wxGTK-gl && \
 wget https://packages.erlang-solutions.com/erlang/rpm/centos/7/x86_64/esl-erlang_22.3.4.1-1~centos~7_amd64.rpm
RUN rpm -i esl-erlang_22.3.4.1-1~centos~7_amd64.rpm
RUN chown root:root /app
USER root:root
ENV HOME=/app
ENV ERTS_PATH=/usr/lib/erlang
CMD [ "make","shell" ]