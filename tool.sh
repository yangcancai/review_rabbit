#!/bin/sh
# Replace environment variables
IMAGE="review_rabbit"
DOCKER_PORT="-p 8081:8081"
DOCKER_PROXY=""
GIT_HOST="github.com"
GIT_IP="140.82.114.4"
APP_VERSION="$(cat VERSION)"
SCP_SRC_FILE="_build/prod/rel/review_rabbit/review_rabbit-${APP_VERSION}.tar.gz"
PROJ_DIR="/app"
SCP_DST_DIR=/data/review_rabbit
APP=review_rabbit
APP_START="bin/$APP daemon"
APP_PID="bin/$APP pid"
APP_VER="bin/$APP versions"
APP_TAR="tar -xf ${APP}-$APP_VERSION.tar.gz -C review_rabbit"
APP_TAR_BAK="mv ${APP}-$APP_VERSION.tar.gz ${APP}-$APP_VERSION.tar.gz.bak"
APP_STOP="bin/$APP stop"
APP_BAK="rm -rf releases_bak && mv releases releases_bak"
APP_BAK_RECOVER="mv releases_bak releases"
. ./scripts/docker.sh
. ./scripts/ssh.sh
cp_static(){
     echo_eval cp -r assets/dist/* apps/review_rabbit/priv/static/
     echo_eval cp -r assets/lib/dist/* apps/review_rabbit/priv/static/
}
cp_doc(){
    echo_eval cp doc/review_rabbit_api.html apps/review_rabbit/priv/static/
}
set_var(){
    # cp_static
    # cp_doc
    export REVIEW_RABBIT_LOG_ROOT="logs"
	export REVIEW_RABBIT_LOG_LEVEL="error"
    export REVIEW_RABBIT_ENABLE_PLUGINS=[jiffy]
}
gen_commit_id(){
    git rev-parse HEAD > GIT_COMMIT_IDS
    git submodule foreach git rev-parse HEAD >> GIT_COMMIT_IDS
}
pull_frontend(){
    echo_eval git submodule update --init --recursive
    echo_eval git submodule foreach git checkout $1
    echo_eval git submodule foreach git pull
}
pull_backend(){
    if [ "$1" != "" ]; then
    echo_eval git checkout $1
    echo_eval git pull
    fi
    gen_commit_id
}
pull(){
    pull_frontend $1
    pull_backend $1
}
# sh tool.sh relup OLD_RELEASE NEW_RELEASE
relup()
{
	rm -rf _build/prod
	git checkout $1 
    cp_static
	rebar3 as prod release
	git checkout $2
    cp_static
	rebar3 as prod release
	rebar3 as prod appup generate
	rebar3 as prod relup tar	
}
replace_os_vars() {
    awk '{
        while(match($0,"[$]{[^}]*}")) {
            var=substr($0,RSTART+2,RLENGTH -3)
            slen=split(var,arr,":-")
            v=arr[1]
            e=ENVIRON[v]
            if(slen > 1 && e=="") {
                i=index(var, ":-"arr[2])
                def=substr(var,i+2)
                gsub("[$]{"var"}",def)
            } else {
                gsub("[$]{"var"}",e)
            }
        }
    }1' < "$1" > "$2"
}
replace_config(){
    set_var
    replace_os_vars config/sys.config.src config/sys.config 
    replace_os_vars config/vm.args.src config/vm.args
}
release(){
    rm -rf _build/prod
    pull $1
    # cp_static
   if [ $1 == "develop" ];then
      cp_doc
    fi
    make tar
}
case $1 in
replace_config) replace_config;;
build_docker) build_docker;;
run_docker) run_docker "sh tool.sh before_script && sh tool.sh consul && make shell";;
tar_docker) tar_docker;;
before_script) before_script;;
sh_docker) sh_docker;;
make_docker) make_docker $2;;
release) release $2;;
tar) release $2
     croc send --code xxxx _build/prod/rel/review_rabbit/review_rabbit-*.tar.gz;;
ssh_restart) ssh_restart;;
git_proxy) git_proxy;;
relup) relup $2 $3;;
*)
echo "Usage: sh tool.sh [command]"
echo "command:"
echo "replace_config       override sys.config and vm.args"
echo "relup release-0.1.0 release-0.1.1               genarate appup tar"
;;
esac