export default function IconButton({ label, children, className = "", type = "button", ...props }) {
  return (
    <button className={`icon-button ${className}`} type={type} title={label} aria-label={label} {...props}>
      {children}
    </button>
  );
}
