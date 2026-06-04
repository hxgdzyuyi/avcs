import { forwardRef } from "react";

const IconButton = forwardRef(function IconButton(
  { label, children, className = "", type = "button", ...props },
  ref,
) {
  return (
    <button
      className={`icon-button ${className}`}
      type={type}
      title={label}
      aria-label={label}
      ref={ref}
      {...props}
    >
      {children}
    </button>
  );
});

export default IconButton;
