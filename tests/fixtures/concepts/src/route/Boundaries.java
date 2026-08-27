package com.kairos.route;

/** A route's own accessors, whose names collide with OKF field names. */
public record Boundaries(String symbol, String language) {
    public String describe() {
        return symbol + " (" + language + ")";
    }
}
