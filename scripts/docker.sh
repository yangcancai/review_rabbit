#!/bin/sh
DOCKER_OPTION=" run -it --rm  -e GIT_USER -e GIT_ACCESS_TOKEN $DOCKER_ENV $DOCKER_PORT  -v "$(pwd):$PROJ_DIR" $IMAGE /bin/bash -c "
build_docker(){
    #docker build --no-cache -t $IMAGE .
    docker build --compress --rm -t $IMAGE .
}
run_docker(){
    docker $DOCKER_OPTION "sh tool.sh before_script && $1"
}
proxy_str(){
echo -e "[https \"https://$GIT_HOST/\"]
        proxy = $DOCKER_PROXY 
[http \"https://$GIT_HOST/\"]
        proxy = $DOCKER_PROXY"
}
git_proxy(){
	echo "$(proxy_str)" >> ~/.gitconfig
}
before_script(){
    unset http_proxy; unset HTTPS_PROXY;unset https_proxy;unset HTTP_PROXY
    git config --global credential.helper 'store --file ~/.git-credentials'
    git_proxy
	echo "$GIT_IP $GIT_HOST" >> /etc/hosts
	echo "https://$GIT_USER:$GIT_ACCESS_TOKEN@$GIT_HOST" > ~/.git-credentials
}
tar_docker(){
    run_docker "make tar "
}
sh_docker(){
    if [ "$1" == "" ]
    then
    run_docker "sh"
    else
    run_docker "$1"
    fi
}
make_docker(){
    run_docker "make $1"
}