package com.example.kitchen;

public final class NoSuchRouteException extends RuntimeException {
  NoSuchRouteException(String path) {
    super(path);
  }
}
