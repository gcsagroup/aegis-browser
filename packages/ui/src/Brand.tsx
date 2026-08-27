import type { ReactNode } from "react";

export function Brand({
  title,
  tagline,
}: {
  title: string;
  tagline?: ReactNode;
}) {
  return (
    <div className="aegis-brand">
      <h1>{title}</h1>
      {tagline ? <span>{tagline}</span> : null}
    </div>
  );
}
