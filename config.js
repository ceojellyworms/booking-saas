// config.js
// Supabase project configuration.
// anon key безопасен для фронта (RLS включён на всех таблицах).

const SUPABASE_URL = "https://kfylzmkwgvdirqdoibif.supabase.co";
const SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtmeWx6bWt3Z3ZkaXJxZG9pYmlmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTEyNDAzMjMsImV4cCI6MjEwNjgxNjMyM30.Ycr1aVYO7A66FTdJ4SoXL0jhjHAOrig4fdq3uoXMAJg";

// Bucket в Supabase Storage для логотипов, баннеров и картинок услуг
const SUPABASE_BUCKET = "project-assets";

// Сколько часов живёт токен сессии админа
const SESSION_TTL_HOURS = 24;

// Ключ localStorage, где хранится токен сессии
const SESSION_STORAGE_KEY = "admin_session_token";

// Префикс localStorage, где хранится признак «это супер-админ»
const SUPER_ADMIN_FLAG = "super_admin_ok";

// Supabase JS SDK подключается через CDN. Файл фиксируем, чтобы не сломалось
// при обновлении минорной версии.
const SUPABASE_SDK_URL = "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js";