closefrom 4

# Not even enough fds to keep the root open
ulimit -n 7
bfs_diff deep -type f -exec bash -c 'echo "${1:0:6}/.../${1##*/} (${#1})"' bash {} \;