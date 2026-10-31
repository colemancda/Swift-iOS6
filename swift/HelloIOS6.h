// C declarations for the @c functions in HelloIOS6.swift.
// Swift's Int is 32 bits on armv7, the same as long.

#ifndef HELLO_IOS6_H
#define HELLO_IOS6_H

/// Writes the Swift greeting into buffer as NUL-terminated UTF-8.
/// Returns the number of bytes written, not counting the NUL.
long hello_greeting(char *buffer, long size);

/// Returns 1² + 2² + ... + n², computed in Swift.
long hello_sum_of_squares(long n);

#endif
