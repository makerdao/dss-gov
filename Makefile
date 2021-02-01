all    :; dapp --use solc:0.6.11 build
clean  :; dapp clean
test   :; dapp --use solc:0.6.11 test -v
deploy-kovan :; make && dapp create DssGov 0xAaF64BFCC32d0F15873a02163e7E500671a4ffcD 0x41F0B6eCaEbfBf85C4EB857116CaeEB0bdC212f0
deploy-mainnet :; make && dapp create DssGov 0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2 0xA618E54de493ec29432EbD2CA7f14eFbF6Ac17F7
