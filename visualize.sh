#!/bin/bash

# if there are many tables on the server that could cause problems for the script
number_of_tables=10000
mysql_options=""
options=""

out_dir_base=`hostname`_environment_`date +%F`
out_dir="$out_dir_base/vis"

sys_format_statement="sys.format_statement"
sys_format_time="sys.format_time"

function usage {
  cat << EOF
 usage: $0 [-h] [-o mysql arguments] [-n number of tables] [-t] [-p pid]
 
 OPTIONS:
    -h        Show this message
    -o string Extra MySQL Arguments, For example: "--defaults-file=/root/.my.cnf.alternatesocket"
    -n int    Max number of tables
    -t        Do not tar the directory after collection is finished
    -p int    Use this specific PID for MySQL when multiple instances are running
    -d string Directory to save the visualize data, by default $out_dir/vis
EOF

}

while getopts ho:d:n:i:trp: flag; do
  case $flag in
    o)
      mysql_options="$OPTARG";
      ;;
    n)
      number_of_tables="$OPTARG";
      ;;
    t)
      SKIPTARRESULT=1;
      ;;
    p)
      PIDTOUSE=$OPTARG
      ;;
    h)
      usage;
      exit 0;
      ;;
    *)
      usage;
      exit 1;
      ;;
  esac
done

shift $(( OPTIND - 1 ));

### Functions

# Try to run a query and print error if it fails.
function check_mysql_connection {
  if [ "`mysql $mysql_options -NBe 'select 1'`" != "1" ] 
  then
    echo "Can't connect to local mysql. Please add connection information to ~/.my.cnf"
    echo "Example: "
    echo "[client]"
    echo "user=percona"
    echo "password=s3cret"
    echo "# If RDS, add host="
    echo ""
    exit 1
  fi
  MAJOR_VERSION=`mysql $mysql_options $options --skip-column-names -e "SELECT SUBSTRING_INDEX(SUBSTRING_INDEX(VERSION(), '-', 1), '.', 1);"`
  MINOR_VERSION=`mysql $mysql_options $options --skip-column-names -e "SELECT SUBSTRING_INDEX(SUBSTRING_INDEX(SUBSTRING_INDEX(VERSION(), '-', 1), '.', 2), '.', -1);"`
  echo "MySQL version: $MAJOR_VERSION.$MINOR_VERSION"
  
  # check if SYS schema query succeeded (do we have SUPER?)
  set +e
  format_statement=`mysql $mysql_options -Nbe 'select sys.format_statement("select 1")' 2>&1`
  if [ $? -ne 0 ]; then
    echo "$format_statement"
    echo 'sys schema is not found or you do not have an access. For MySQL 5.6 install sys schema...'
    if ! test -f "sys_56.sql"
    then
		echo '... trying to download sys...'
		wget -O sys_56.sql 'https://raw.githubusercontent.com/mysql/mysql-sys/master/sys_56.sql'
	fi
	echo "To get better output, install sys schema by running: mysql $mysql_options < sys_56.sql"
	echo "Then rerun the script"
	sys_format_statement=""
	sys_format_time=""
  fi
  set -e
}


### Main

set -ue

#check_mysql_connection

mkdir -p $out_dir

### Generate JSONs

db="performance_schema_t"

for i in {1..4} 
do
	if [ $i -eq 1 ]; then
		grp=" left(digest_text, 7)"
		where=""
	fi
	if [ $i -eq 2 ]; then
	        grp=" SUBSTRING_INDEX(SUBSTRING(digest_text, locate('from ', digest_text)+5), ' ', 2)";
                where=" and locate('from ', digest_text) > 0 " 
	fi
	if [ $i -eq 3 ]; then
		grp=" left(SCHEMA_NAME, 100)";
		where=""
	fi
        if [ $i -eq 4 ]; then
                grp=" left(digest_text, 7)"
		where=" and (SUM_CREATED_TMP_DISK_TABLES > 0 or SUM_SORT_MERGE_PASSES > 0) "
	fi

q=$(cat <<EOF | tr -d '\n' | tr '\t' ' '
	SET group_concat_max_len=100000000;
	SET @sys.statement_truncate_len = 80;
	SET NAMES utf8;
	SELECT group_concat('{', sch, ', "values": [', grp, ']}') FROM (
	SELECT concat('"key": "', $grp, '"') as sch,
	       group_concat('{
	           "x":"', round((COUNT_STAR / (select sum(COUNT_STAR) from events_statements_summary_by_digest WHERE left(digest_text, 7) in ('SELECT', 'UPDATE', 'DELETE', 'INSERT', 'CREATE')))*100, 4) , '",
	           "y":', AVG_TIMER_WAIT/1000000000, ', 
	           "size":', round((SUM_TIMER_WAIT/(select sum(SUM_TIMER_WAIT) from events_statements_summary_by_digest))*100, 8), ', 
	           "shape":"circle", ', 
	           '"digest_text":"', ${sys_format_statement}(digest_text), '",'
		   '"tooltip":"', concat(
							'<td>q</td><td><b>', sys.format_statement(digest_text), '</b></td><tr>',
							'<td>db</td><td><b>', SCHEMA_NAME, '</b></td><tr>',
							'<td>full_scan</td><td><b>', IF(SUM_NO_GOOD_INDEX_USED > 0 OR SUM_NO_INDEX_USED > 0, '*', ''), '</b></td><tr>',
							'<td>exec_count</td><td><b>', COUNT_STAR, '</b></td><tr>',
							'<td>err_count</td><td><b>', SUM_ERRORS, '</b></td><tr>',
							'<td>warn_count</td><td><b>', SUM_WARNINGS, '</b></td><tr>',
							'<td>total_latency</td><td><b>', ${sys_format_time}(SUM_TIMER_WAIT), '</b></td><tr>',
							'<td>max_latency</td><td><b>', ${sys_format_time}(MAX_TIMER_WAIT), '</b></td><tr>',
							'<td>avg_latency</td><td><b>', ${sys_format_time}(AVG_TIMER_WAIT), '</b></td><tr>',
							'<td>lock_latency</td><td><b>', ${sys_format_time}(SUM_LOCK_TIME), '</b></td><tr>',
							'<td>rows_sent</td><td><b>', SUM_ROWS_SENT, '</b></td><tr>',
							'<td>rows_sent_avg</td><td><b>', ROUND(IFNULL(SUM_ROWS_SENT / NULLIF(COUNT_STAR, 0), 0)), '</b></td><tr>',
							'<td>rows_examined</td><td><b>', SUM_ROWS_EXAMINED, '</b></td><tr>',
							'<td>rows_examined_avg</td><td><b>', ROUND(IFNULL(SUM_ROWS_EXAMINED / NULLIF(COUNT_STAR, 0), 0)) , '</b></td><tr>',
							'<td>rows_affected</td><td><b>', SUM_ROWS_AFFECTED, '</b></td><tr>',
							'<td>rows_affected_avg</td><td><b>', ROUND(IFNULL(SUM_ROWS_AFFECTED / NULLIF(COUNT_STAR, 0), 0)) , '</b></td><tr>',
							'<td>tmp_tables</td><td><b>', SUM_CREATED_TMP_TABLES, '</b></td><tr>',
							'<td>tmp_disk_tables</td><td><b>', SUM_CREATED_TMP_DISK_TABLES, '</b></td><tr>',
							'<td>rows_sorted</td><td><b>', SUM_SORT_ROWS, '</b></td><tr>',
							'<td>sort_merge_passes</td><td><b>', SUM_SORT_MERGE_PASSES, '</b></td><tr>',
							'<td>digest</td><td><b>', DIGEST, '</b></td><tr>',
							'<td>first_seen</td><td><b>', FIRST_SEEN, '</b></td><tr>',
							'<td>last_seen</td><td><b>', LAST_SEEN, '</b></td><tr>'
		   ),
	       '"}') as grp
	FROM events_statements_summary_by_digest
	WHERE 
	round((SUM_TIMER_WAIT/(select sum(SUM_TIMER_WAIT) from events_statements_summary_by_digest))*100, 4) > 0.05
	and left(digest_text, 7) in ('SELECT', 'UPDATE', 'DELETE', 'INSERT', 'CREATE')
	$where
	GROUP BY $grp 
	) as t;
EOF
) 
	#echo "$grp\n$where\n"
	echo "[" > ${out_dir}/q$i.json
	res=$(mysql $mysql_options  $db -Nbe "$q")
	if [ "$res" == "NULL" ]; then
		echo "No results for q$i! Writing blank doc"
		res=""
	fi
	echo $res >> ${out_dir}/q$i.json
	echo "]" >> ${out_dir}/q$i.json
done 

cp index.html $out_dir/
cp nv.d3.* $out_dir/

if [ ! "${SKIPTARRESULT+defined}" ]; then
  echo "Compressing..."
  tar czf ${out_dir_base}.tgz ${out_dir_base}
  echo "Filename:" ${out_dir}.tgz
else
  echo "Skipped results compression."
  echo "Directory name:" ${out_dir}
fi

echo "All tasks finished."

cd $out_dir/
ls -lah
python -m SimpleHTTPServer 
cd ../../
