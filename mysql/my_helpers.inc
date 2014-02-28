cmd () {
 local realcmd='mysql' my_opts sql_cmd
 local ret rx
 if [[ ${1:0:1} == '&' ]]; then
  realcmd=${1:1}
  shift
 fi
 if [[ ${1:0:1} == '-' ]]; then
  rx='(^(.*\s)?)--((\s.*)?$)'  
  if [[ $@ =~ $rx ]]; then
   my_opts=${BASH_REMATCH[1]}
   sql_cmd=${BASH_REMATCH[3]}
  else
   my_opts=$@
  fi
 else
  sql_cmd=$@
 fi
 my_opts+=${DB[USER]:+ -u ${DB[USER]}}${DB[PASS]:+ -p"${DB[PASS]}"}${DB[NAME]:+ ${DB[NAME]}}
 [[ $TRACE -eq 1 ]] && logger -t SUperCMD  -p local3.info  "realcmd=$realcmd, my_opts=$my_opts, sql_cmd=${sql_cmd%;};"
 if [[ $sql_cmd ]]; then
  $realcmd $my_opts <<<"${sql_cmd%;};"
  ret=$?
 else
  if [[ -t 0 ]]; then
   $realcmd $my_opts
  else
   $realcmd $my_opts < <(cat -)
  fi
  ret=$?
 fi
 return $ret
}

log () {
 local svr=${1,,}; shift
 logger -t ${slf[TAG]} -p local3.$svr "$@"
 return $?
}