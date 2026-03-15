/**
 * @file result.h
 *
 * Result codes for libtermplex-vt operations.
 */

#ifndef TERMPLEX_VT_RESULT_H
#define TERMPLEX_VT_RESULT_H

/**
 * Result codes for libtermplex-vt operations.
 */
typedef enum {
    /** Operation completed successfully */
    TERMPLEX_SUCCESS = 0,
    /** Operation failed due to failed allocation */
    TERMPLEX_OUT_OF_MEMORY = -1,
    /** Operation failed due to invalid value */
    TERMPLEX_INVALID_VALUE = -2,
} TermplexResult;

#endif /* TERMPLEX_VT_RESULT_H */
