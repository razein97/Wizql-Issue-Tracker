#macos x86_64

arch -x86_64 env \
  GOARCH=amd64 \
  GOOS=darwin \
  CGO_ENABLED=1 \
  PATH="/usr/local/bin:$PATH" \
  ./make build -pkgs=mongodump,mongorestore
  
  
  # macos arm64
    ./make build -pkgs=mongodump,mongorestore



    wget https://go.dev/dl/go1.25.5.linux-amd64.tar.gz
    sudo tar -xvf go1.25.5.linux-amd64.tar.gz -C /usr/local

export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export PATH=$GOPATH/bin:$GOROOT/bin:$PATH



source ~/.profile
source ~/.bashrc
