all    :; dapp --use solc:0.6.11 build
clean  :; dapp clean
test   :; dapp --use solc:0.6.11 test -v
deploy :; make && dapp create DssGov
