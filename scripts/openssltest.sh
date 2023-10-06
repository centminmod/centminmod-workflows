#!/bin/bash

# Check if an argument is provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 {boringssl|openssl111|openssl30|openssl31|bssl|opensslquic}"
    exit 1
fi

LIB=$1

function process_openssl_output() {
    local rsa_line=$(echo "$1" | grep "rsa 2048 bits")
    local ecdsa_line=$(echo "$2" | grep "256 bits ecdsa")
    
    if [[ ! -z $rsa_line ]]; then
        local rsa_sign=$(echo $rsa_line | awk '{print $6}')
        local rsa_verify=$(echo $rsa_line | awk '{print $7}')
        echo "rsa 2048 bits signs/s: $rsa_sign"
        echo "rsa 2048 bits verify/s: $rsa_verify"
    fi
    
    if [[ ! -z $ecdsa_line ]]; then
        local ecdsa_sign=$(echo $ecdsa_line | awk '{print $7}')
        local ecdsa_verify=$(echo $ecdsa_line | awk '{print $8}')
        echo "256 bits ecdsa (nistp256) signs/s: $ecdsa_sign"
        echo "256 bits ecdsa (nistp256) verify/s: $ecdsa_verify"
    fi
}

case $LIB in
    boringssl|bssl)
        BINARY="/opt/boringssl/bin/bssl"
        if [ -f "$BINARY" ]; then
            echo "Benchmarking BoringSSL..."
            OUTPUTRSA=$($BINARY speed -filter RSA | grep 'RSA 2048')
            echo "$OUTPUTRSA"
            OUTPUTECDSA=$($BINARY speed -filter ECDSA | grep 'ECDSA P-256')
            echo "$OUTPUTECDSA"
        fi
        ;;
    openssl111|openssl30|openssl31)
        BINARY="/opt/openssl/bin/openssl"
        if [ -f "$BINARY" ]; then
            echo "Benchmarking OpenSSL $LIB..."
            RSA_OUTPUT=$($BINARY speed rsa2048)
            ECDSA_OUTPUT=$($BINARY speed ecdsap256)
            process_openssl_output "$RSA_OUTPUT" "$ECDSA_OUTPUT"
        fi
        ;;
    opensslquic)
        BINARY="/opt/openssl-quic/bin/openssl"
        if [ -f "$BINARY" ]; then
            echo "Benchmarking OpenSSL-QUIC..."
            RSA_OUTPUT=$($BINARY speed rsa2048)
            ECDSA_OUTPUT=$($BINARY speed ecdsap256)
            process_openssl_output "$RSA_OUTPUT" "$ECDSA_OUTPUT"
        fi
        ;;
    *)
        echo "Invalid argument. Usage: $0 {boringssl|openssl111|openssl30|openssl31|bssl|opensslquic}"
        exit 1
        ;;
esac