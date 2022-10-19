skip_unless test "$SUDO"
skip_unless test "$UNAME" = "Linux"

rm -rf scratch/*
$TOUCH scratch/{file,null}
sudo mount --bind /dev/null scratch/null
ln -s /dev/null scratch/link

bfs_diff -L scratch -type c
ret=$?

sudo umount scratch/null
return $ret
