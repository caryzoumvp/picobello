xhost +SI:localuser:root
docker run -it \
    -v $PWD:/workspace \
    -v $HOME/questa/questasim:/opt/questasim \
    -e DISPLAY=$DISPLAY \
    -e XAUTHORITY=/root/.Xauthority \
    -v /run/user/1000/gdm/Xauthority:/root/.Xauthority:ro \
    -v /tmp/.X11-unix:/tmp/.X11-unix  \
    --network host \
    picobello
