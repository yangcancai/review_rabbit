#!/bin/bash
echo 'review_rabbit: pre_install_upgrade.sh'
UP_VSN=$UPGRADE_VSN
DOWN_VSN=$UPGRADE_VSN
echo "pre_install_upgrade.sh: $COMMAND $REL_VSN to $UPGRADE_VSN"
check_replace_os_vars() {
    IN_FILE_PATH=$1
	echo $IN_FILE_PATH
    OUT_FILE_PATH="$IN_FILE_PATH"
    SRC_FILE_PATH="$IN_FILE_PATH.src"
    ORIG_FILE_PATH="$IN_FILE_PATH.orig"
    if [ -f "$SRC_FILE_PATH" ]; then
        replace_os_vars "$SRC_FILE_PATH" "$OUT_FILE_PATH"
    elif [ $RELX_REPLACE_OS_VARS ]; then
        # Create a new file in the same location as original
        OUT_FILE_PATH=$(make_out_file_path $IN_FILE_PATH)
        # If vm.args.orig or sys.config.orig is present then use that
        if [ -f "$ORIG_FILE_PATH" ]; then
           IN_FILE_PATH="$ORIG_FILE_PATH"
        fi

        # apply the environment variable substitution to $IN_FILE_PATH
        # the result is saved to $OUT_FILE_PATH
        # if they are both the same, then ensure that we don't clobber
        # the file by saving a backup with the .orig extension
        if [ "$IN_FILE_PATH" = "$OUT_FILE_PATH" ]; then
            cp "$IN_FILE_PATH" "$ORIG_FILE_PATH"
            replace_os_vars "$ORIG_FILE_PATH" "$OUT_FILE_PATH"
        else
            replace_os_vars "$IN_FILE_PATH" "$OUT_FILE_PATH"
        fi
    else
        # If vm.arg.orig or sys.config.orig is present then use that
        if [ -f "$ORIG_FILE_PATH" ]; then
           cp "$ORIG_FILE_PATH" "$OUT_FILE_PATH"
        fi
    fi
    echo $OUT_FILE_PATH
}
if [ $COMMAND == 'downgrade' ];then
	check_replace_os_vars ./releases/$DOWN_VSN/sys.config
	elif [ $COMMAND == 'upgrade' ];then
	bin/crm_push_server unpack $UP_VSN
	check_replace_os_vars ./releases/$UP_VSN/sys.config
fi
