package com.example.kitchen;

import java.util.HashMap;
import java.util.Map;

public final class Router {
  private final Map<String, Handler> handlers = new HashMap<>();
  private final Handler fallback;

  public Router(Handler fallback) {
    this.fallback = fallback;
  }

  public void add(String path, Handler handler) {
    handlers.put(path, handler);
  }

  public Handler route(String path) {
    Handler handler = handlers.get(path);
    return handler == null ? fallback : handler;
  }

  public int size() {
    return handlers.size();
  }
}
