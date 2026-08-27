package fixture.util;

import javax.annotation.Generated;

/**
 * Hand-written, with one accessor a code generator filled in. The class is
 * still ours to document: the annotation below is on a member, not on the type.
 */
public final class Accessors {
  private String name;

  @Generated("lombok")
  public String getName() {
    return this.name;
  }

  public void rename(String next) {
    this.name = next;
  }
}
