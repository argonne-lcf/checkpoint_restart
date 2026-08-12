#!/bin/bash
mkdir -p /tmp/$USER/pbs/
export PBS_TMPDIR=/tmp/$USER/pbs
n=0

echo "Build a $3 nodes nodefile from $1, which contains $2 nodes"
for ip in `cat $1 | uniq`;
do
   (
      ping $ip -c2 &> /dev/null ;

      if [ $? -eq 0 ];
      then
	  echo $ip >& $PBS_TMPDIR/node$n.dat
      else
	  rm -f $PBS_TMPDIR/node$n.dat
	  touch $PBS_TMPDIR/node$n.dat
      fi
   )&
   n=$((n+1))
done
wait
rm -rf $3
if [[ $n -lt $3 ]];then
    echo "The number of nodes available is smaller than requested; existing..."
    exit 100
fi

export SELECT=$2
echo "Total number of nodes checked: $n"
for i in `seq 0 $((SELECT-1))`
do
    cat $PBS_TMPDIR/node$i.dat >> $3
done

echo "Number of nodes that are selected: $(cat $3 | uniq | wc -l)"
rm -rf /tmp/$USER/pbs/
