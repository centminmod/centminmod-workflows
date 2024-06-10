#!/bin/bash

# Check if an argument is provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 {boringssl|awslc|openssl111|openssl30|openssl31|openssl32|openssl33|bssl|opensslquic|opensslsys}"
    exit 1
fi

LIB=$1

function process_openssl_output() {
    rsa_input="$1"
    ecdsa_input="$2"
    local rsa_line=$(echo "$rsa_input" 2>&1 | grep "rsa 2048 bits" | grep -v 'Doing ')
    local ecdsa_line=$(echo "$ecdsa_input" 2>&1 | grep "256 bits ecdsa" | grep -v 'Doing ')
    
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

function process_openssl_output32() {
    rsa_input="$1"
    ecdsa_input="$2"
    local rsa_line=$(echo "$rsa_input" 2>&1 | grep "rsa  2048 bits" | grep -v 'Doing ')
    local ecdsa_line=$(echo "$ecdsa_input" 2>&1 | grep "256 bits ecdsa" | grep -v 'Doing ')
    
    if [[ ! -z $rsa_line ]]; then
        local rsa_sign=$(echo $rsa_line | awk '{print $8}')
        local rsa_verify=$(echo $rsa_line | awk '{print $9}')
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

function process_curve_output() {
    # For OpenSSL
    local openssl_output="$1"
    local openssl_curve_lines=$(echo "$openssl_output" | grep -E '256 bits ecdh \(nistp256\)|253 bits ecdh \(X25519\)')
    echo "$openssl_curve_lines"

    # For BoringSSL with filter X25519
    local bssl_x25519_output="$2"
    local bssl_x25519_lines=$(echo "$bssl_x25519_output" | grep -E 'multiplication operations|Ed25519 signing operations|Ed25519 verify operations')
    echo "$bssl_x25519_lines"

    # For BoringSSL with filter P-256
    local bssl_p256_output="$3"
    local bssl_p256_lines=$(echo "$bssl_p256_output" | grep -E 'ECDH P-256 operations|ECDSA P-256 signing operations|ECDSA P-256 verify operations')
    echo "$bssl_p256_lines"
}

function process_curve_output32() {
    # For OpenSSL
    local openssl_output="$1"
    local openssl_curve_lines=$(echo "$openssl_output" | grep -E '256 bits ecdh \(nistp256\)|253 bits ecdh \(X25519\)')
    echo "$openssl_curve_lines"

    # For BoringSSL with filter X25519
    local bssl_x25519_output="$2"
    local bssl_x25519_lines=$(echo "$bssl_x25519_output" | grep -E 'multiplication operations|Ed25519 signing operations|Ed25519 verify operations')
    echo "$bssl_x25519_lines"

    # For BoringSSL with filter P-256
    local bssl_p256_output="$3"
    local bssl_p256_lines=$(echo "$bssl_p256_output" | grep -E 'ECDH P-256 operations|ECDSA P-256 signing operations|ECDSA P-256 verify operations')
    echo "$bssl_p256_lines"
}

case $LIB in
    boringssl)
        BINARY="/opt/boringssl/bin/bssl"
        if [ -f "$BINARY" ]; then
            echo "Benchmarking BoringSSL..."
            OUTPUTRSA=$($BINARY speed -filter RSA | grep 'RSA 2048' 2>&1)
            echo "$OUTPUTRSA"
            OUTPUTECDSA=$($BINARY speed -filter ECDSA | grep 'ECDSA P-256' 2>&1)
            echo "$OUTPUTECDSA"
            # Additional benchmarking for curves X25519 and P-256
            OUTPUTX25519=$($BINARY speed -filter X25519 2>&1)
            OUTPUTP256=$($BINARY speed -filter P-256 2>&1)
            process_curve_output "" "$OUTPUTX25519" "$OUTPUTP256"
         fi
        ;;
    awslc)
        BINARY="/opt/aws-lc-install/bin/bssl"
        if [ -f "$BINARY" ]; then
            echo "Benchmarking AWS-LC..."
            OUTPUTRSA=$($BINARY speed -filter RSA | grep 'RSA 2048' 2>&1)
            echo "$OUTPUTRSA"
            OUTPUTECDSA=$($BINARY speed -filter ECDSA | grep 'ECDSA P-256' 2>&1)
            echo "$OUTPUTECDSA"
            # Additional benchmarking for curves X25519 and P-256
            OUTPUTX25519=$($BINARY speed -filter X25519 2>&1)
            OUTPUTP256=$($BINARY speed -filter P-256 2>&1)
            process_curve_output "" "$OUTPUTX25519" "$OUTPUTP256"
         fi
        ;;
    openssl111|openssl30|openssl31)
        BINARY="/opt/openssl/bin/openssl"
        BINARY_VER=$($BINARY version 2>&1 | awk '{print $1,$2}')
        if [ -f "$BINARY" ]; then
            echo "Benchmarking ${BINARY_VER} $LIB..."
            RSA_OUTPUT=$($BINARY speed rsa2048 2>&1)
            ECDSA_OUTPUT=$($BINARY speed ecdsap256 2>&1)
            process_openssl_output "$RSA_OUTPUT" "$ECDSA_OUTPUT"
            # Additional benchmarking for curves
            CURVE_OUTPUT=$($BINARY speed ecdhx25519 ecdhp256 2>&1)
            process_curve_output "$CURVE_OUTPUT" "" ""
        fi
        ;;
    openssl32)
        BINARY="/opt/openssl/bin/openssl"
        BINARY_VER=$($BINARY version 2>&1 | awk '{print $1,$2}')
        if [ -f "$BINARY" ]; then
            echo "Benchmarking ${BINARY_VER} $LIB..."
            RSA_OUTPUT=$($BINARY speed rsa2048 2>&1)
            ECDSA_OUTPUT=$($BINARY speed ecdsap256 2>&1)
            process_openssl_output32 "$RSA_OUTPUT" "$ECDSA_OUTPUT"
            # Additional benchmarking for curves
            CURVE_OUTPUT=$($BINARY speed ecdhx25519 ecdhp256 2>&1)
            process_curve_output32 "$CURVE_OUTPUT" "" ""
        fi
        ;;
    openssl33)
        BINARY="/opt/openssl/bin/openssl"
        BINARY_VER=$($BINARY version 2>&1 | awk '{print $1,$2}')
        if [ -f "$BINARY" ]; then
            echo "Benchmarking ${BINARY_VER} $LIB..."
            RSA_OUTPUT=$($BINARY speed rsa2048 2>&1)
            ECDSA_OUTPUT=$($BINARY speed ecdsap256 2>&1)
            process_openssl_output32 "$RSA_OUTPUT" "$ECDSA_OUTPUT"
            # Additional benchmarking for curves
            CURVE_OUTPUT=$($BINARY speed ecdhx25519 ecdhp256 2>&1)
            process_curve_output32 "$CURVE_OUTPUT" "" ""
        fi
        ;;
    opensslsys)
        BINARY="/usr/bin/openssl"
        BINARY_VER=$($BINARY version 2>&1 | awk '{print $1,$2}')
        if [ -f "$BINARY" ]; then
            echo "Benchmarking ${BINARY_VER} System..."
            RSA_OUTPUT=$($BINARY speed rsa2048 2>&1)
            ECDSA_OUTPUT=$($BINARY speed ecdsap256 2>&1)
            process_openssl_output "$RSA_OUTPUT" "$ECDSA_OUTPUT"
            # Additional benchmarking for curves
            CURVE_OUTPUT=$($BINARY speed ecdhx25519 ecdhp256 2>&1)
            process_curve_output "$CURVE_OUTPUT" "" ""
        fi
        ;;
    opensslquic)
        BINARY="/opt/openssl-quic/bin/openssl"
        BINARY_VER=$($BINARY version 2>&1 | awk '{print $1,$2}')
        if [ -f "$BINARY" ]; then
            echo "Benchmarking ${BINARY_VER}..."
            RSA_OUTPUT=$($BINARY speed rsa2048 2>&1)
            ECDSA_OUTPUT=$($BINARY speed ecdsap256 2>&1)
            process_openssl_output "$RSA_OUTPUT" "$ECDSA_OUTPUT"
            # Additional benchmarking for curves
            CURVE_OUTPUT=$($BINARY speed ecdhx25519 ecdhp256 2>&1)
            process_curve_output "$CURVE_OUTPUT" "" ""
        fi
        ;;
    *)
        echo "Invalid argument. Usage: $0 {boringssl|openssl111|openssl30|openssl31|openssl32|openssl33|bssl|opensslquic|opensslsys}"
        exit 1
        ;;
esac
