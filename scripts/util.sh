#!/bin/bash
## how to use
#SSH_USER="admin"
#SSH_PORT=99
#SSH_IP=127.0.0.1
#SCP_SRC_FILE=review_rabbit.tar.gz
#SCP_DST_DIR=/data/crm/review_rabbit
#APP=review_rabbit
#APP_START="bin/$APP daemon"
#APP_PID="bin/$APP pid"
#APP_VER="bin/$APP version"
#APP_TAR="tar -xf ${APP}.tar.gz"
#APP_TAR_BAK="mv ${APP}.tar.gz ${APP}.tar.gz.bak"
#APP_STOP="bin/$APP stop"
#APP_BAK="rm -rf releases_bak && mv releases releases_bak"
#APP_BAK_RECOVER="mv releases_bak releases"
#. ./util.sh
## restart
print()
{
#echo -e "\\033[34m 蓝色字 \033[0m"
#echo -e "\\033[30m 黑色字 \033[0m"
#echo -e "\\033[31m 红色字 \033[0m"
#echo -e "\\033[32m 绿色字 \033[0m"
#echo -e "\\033[33m 黄色字 \033[0m"
#echo -e "\\033[34m 蓝色字 \033[0m"
#echo -e "\\033[35m 紫色字 \033[0m"
#echo -e "\\033[36m 天蓝字 \033[0m"
#echo -e "\033[37m 白色字 \033[0m"
echo -e "\033[32m ==> $1\033[0m"
}
warning_log(){
echo -e "\033[33m ==> $1 \033[0m"
}
error_log(){
echo -e "\033[31m ==> $1 \033[0m"
}
echo_eval()
{
	CMD="$1"
	i=0
	for par in $@; do
	if [ $i -ne 0 ];then
		CMD="$CMD $par"
	fi
	let i=i+1
	done
	print "$CMD"		
	eval $CMD
	if [ $? -ne 0 ]; then
		error_log "eval {$CMD} ERROR !!!!!"
		exit 1
	else
		print "eval {$CMD} SUCCESS "
		return 0
	fi
}
cmd_exists()
{
	local ret=0;
	command -v $1 >/dev/null 2>&1 || { local ret=1; }
	if [ "$ret" -ne 0 ]; then
		return 0;
	fi
	return 1
}
create_dir()
{
	if [ ! -d $1 ]; then
		echo_eval mkdir $1
	else
		print "$1 directory already exists"
	fi
}
create_file()
{
	if [ ! -f $1 ]; then
		touch $1
	fi
}
install_normal()
{
	cmd_exists rz
	if [ $? -eq 0 ]; then
		echo_eval yum -y install lrzsz	
	fi
}
####
### tar and restart shell 
### 
env_str(){
	STR="SSH_USER=\"$SSH_USER\"
SSH_PORT=$SSH_PORT
SSH_IP=\"$SSH_IP\"
SCP_SRC_FILE=\"$SCP_SRC_FILE\"
SCP_DST_DIR=\"$SCP_DST_DIR\"
APP=$APP
APP_START=\"$APP_START\"
APP_PID=\"$APP_PID\"
APP_VER=\"$APP_VER\"
APP_TAR=\"$APP_TAR\"
APP_TAR_BAK=\"$APP_TAR_BAK\"
APP_STOP=\"$APP_STOP\"
APP_BAK=\"$APP_BAK\"
APP_BAK_RECOVER=\"$APP_BAK_RECOVER\""
	echo -e "$STR"
}
do_tar(){
        echo_eval $APP_TAR 
        if [ $? -ne 0 ]; then
                return 1;
        else
                echo_eval $APP_TAR_BAK 
        fi
}
start(){
        echo_eval $APP_START
        echo_eval sleep 10s
        echo_eval $APP_PID
        if [ $? -eq 0 ]; then
                echo_eval $APP_VER
                print "start $APP success !!"
        else
                error_log "start $APP error !!"
        fi

}
restart(){
        echo_eval cd $APP
        echo_eval $APP_PID
        echo_eval $APP_VER
        if [ $? -eq 0 ]; then
                echo_eval $APP_STOP
        fi
        echo_eval $APP_BAK
        echo_eval cd ..
        do_tar
        if [ $? -eq 0 ]; then
                echo_eval cd $APP
                start
        else
                # recover
                warning_log "will start the old version"
                echo_eval cd $APP
                echo_eval $APP_BAK_RECOVER
                start
        fi
}
