package fixture.generated;

/**
 * Hand-written, despite living beside the generator's output: this class
 * documents the @Generated annotation that fixture-codegen stamps onto what it
 * writes, and carries none itself.
 */
// @Generated marks the classes fixture-codegen owns. This one is ours.
@NotGenerated("hand-written")
public final class Handwritten {
  // Notes on fixture-codegen's output:
  // - @Generated annotations are added to every class it writes.
  // - the package is always fixture.generated.
  public String describe() {
    return "not generated";
  }
}
