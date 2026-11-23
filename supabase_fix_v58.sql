-- v58: người đăng tải (Creator / Bbi share comm) tự tạo, sửa, xóa NHÓM của mình và đăng / sửa LINK của mình.
-- Cách làm: các hàm chạy phía server (SECURITY DEFINER), tự kiểm tra quyền sở hữu, nên không phụ thuộc
-- các policy cũ của bảng categories / library_items.
-- File này đứng một mình: chỉ cần chạy file này (thay cho v56 và v57). Chạy lại nhiều lần vẫn an toàn.
-- Chạy trong Supabase → SQL Editor.

-- 0. Cột chủ sở hữu + điền sẵn cho nhóm cũ theo tên hiển thị (chỉ khi tên khớp đúng 1 người)
ALTER TABLE public.categories ADD COLUMN IF NOT EXISTS owner_id uuid REFERENCES auth.users(id) ON DELETE SET NULL;

UPDATE public.categories c
SET owner_id = p.user_id
FROM public.creator_profiles p
WHERE c.owner_id IS NULL
  AND lower(trim(c.owner_name)) = lower(trim(p.display_name))
  AND (SELECT count(*) FROM public.creator_profiles p2
       WHERE lower(trim(p2.display_name)) = lower(trim(c.owner_name))) = 1;

-- 1. Hàm phụ
CREATE OR REPLACE FUNCTION public._my_display_name() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT trim(display_name) FROM public.creator_profiles WHERE user_id = auth.uid() LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public._my_can(p_section text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.creator_profiles p
    WHERE p.user_id = auth.uid()
      AND ((p_section = 'creator' AND p.can_creator) OR (p_section = 'commission' AND p.can_commission))
  )
$$;

CREATE OR REPLACE FUNCTION public._owns_cat(p_owner_id uuid, p_owner_name text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT auth.uid() IS NOT NULL AND (
    p_owner_id = auth.uid()
    OR (p_owner_id IS NULL AND lower(trim(p_owner_name)) = lower(COALESCE(public._my_display_name(), chr(1))))
  )
$$;

-- 2. Thêm phân loại nhỏ (kiêm tạo nhóm mới). Tái sử dụng "chỗ trống" nếu nhóm đang rỗng.
CREATE OR REPLACE FUNCTION public.my_cat_add(p_section text, p_group text, p_name text)
RETURNS public.categories LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_name text := public._my_display_name(); r public.categories; ph text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Bạn cần đăng nhập'; END IF;
  IF v_name IS NULL OR v_name = '' THEN RAISE EXCEPTION 'Hồ sơ chưa có tên hiển thị'; END IF;
  IF p_section NOT IN ('creator','commission') OR NOT public._my_can(p_section) THEN
    RAISE EXCEPTION 'Bạn chưa được duyệt quyền ở khu vực này'; END IF;
  IF COALESCE(trim(p_group),'') = '' OR COALESCE(trim(p_name),'') = '' THEN
    RAISE EXCEPTION 'Thiếu tên nhóm hoặc tên phân loại'; END IF;

  SELECT c.id::text INTO ph FROM public.categories c
  WHERE c.section = p_section AND public._owns_cat(c.owner_id, c.owner_name)
    AND COALESCE(c.group_name,'CHAR') = trim(p_group)
    AND (trim(COALESCE(c.name,'')) = '' OR c.name = '__empty__')
  LIMIT 1;
  IF ph IS NOT NULL THEN
    UPDATE public.categories SET name = trim(p_name), owner_id = auth.uid() WHERE id::text = ph RETURNING * INTO r;
    RETURN r;
  END IF;

  INSERT INTO public.categories (main, section, owner_name, owner_id, group_name, name, subcategories, slug, sort_order)
  VALUES (p_section, p_section, v_name, auth.uid(), trim(p_group), trim(p_name),
          (jsonb_populate_record(NULL::public.categories, '{"subcategories":[]}'::jsonb)).subcategories,
          'u-' || substr(md5(random()::text || clock_timestamp()::text), 1, 8), 60)
  RETURNING * INTO r;
  RETURN r;
END $$;

-- 3. Đổi tên nhóm lớn
CREATE OR REPLACE FUNCTION public.my_group_rename(p_section text, p_old text, p_new text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n integer;
BEGIN
  IF COALESCE(trim(p_new),'') = '' THEN RAISE EXCEPTION 'Tên nhóm không được để trống'; END IF;
  UPDATE public.categories SET group_name = trim(p_new)
  WHERE section = p_section AND COALESCE(group_name,'CHAR') = p_old AND public._owns_cat(owner_id, owner_name);
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE EXCEPTION 'Không tìm thấy nhóm này trong danh sách của bạn'; END IF;
  RETURN n;
END $$;

-- 4. Đổi tên phân loại nhỏ
CREATE OR REPLACE FUNCTION public.my_cat_rename(p_id text, p_name text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n integer;
BEGIN
  IF COALESCE(trim(p_name),'') = '' THEN RAISE EXCEPTION 'Tên không được để trống'; END IF;
  UPDATE public.categories SET name = trim(p_name)
  WHERE id::text = p_id AND public._owns_cat(owner_id, owner_name);
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE EXCEPTION 'Không tìm thấy phân loại này trong danh sách của bạn'; END IF;
  RETURN n;
END $$;

-- 5. Lưu danh sách mục con
CREATE OR REPLACE FUNCTION public.my_cat_subs(p_id text, p_subs text[])
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n integer;
BEGIN
  UPDATE public.categories
  SET subcategories = (jsonb_populate_record(NULL::public.categories,
        jsonb_build_object('subcategories', to_jsonb(COALESCE(p_subs, '{}'::text[]))))).subcategories
  WHERE id::text = p_id AND public._owns_cat(owner_id, owner_name);
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE EXCEPTION 'Không tìm thấy phân loại này trong danh sách của bạn'; END IF;
  RETURN n;
END $$;

-- 6. Xóa phân loại / cả nhóm (p_keep_last = true: giữ lại nhóm dưới dạng chỗ trống thay vì xóa hẳn dòng)
CREATE OR REPLACE FUNCTION public.my_cat_delete(p_ids text[], p_keep_last boolean DEFAULT false)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n integer;
BEGIN
  IF EXISTS (SELECT 1 FROM public.library_items li WHERE li.category_id::text = ANY(p_ids)) THEN
    RAISE EXCEPTION 'Còn link trong mục này. Hãy chuyển hoặc xóa link trước.'; END IF;
  IF p_keep_last THEN
    UPDATE public.categories
    SET name = '__empty__',
        subcategories = (jsonb_populate_record(NULL::public.categories, '{"subcategories":[]}'::jsonb)).subcategories
    WHERE id::text = ANY(p_ids) AND public._owns_cat(owner_id, owner_name);
  ELSE
    DELETE FROM public.categories WHERE id::text = ANY(p_ids) AND public._owns_cat(owner_id, owner_name);
  END IF;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE EXCEPTION 'Không tìm thấy mục này trong danh sách của bạn'; END IF;
  RETURN n;
END $$;

-- 7. Đăng / sửa LINK (p_id = null → đăng mới)
CREATE OR REPLACE FUNCTION public.my_item_save(p_id text, p_row jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.library_items; cat public.categories; res jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Bạn cần đăng nhập'; END IF;
  r := jsonb_populate_record(NULL::public.library_items, p_row);
  SELECT * INTO cat FROM public.categories WHERE id = r.category_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Phân loại không tồn tại'; END IF;
  IF NOT public._my_can(cat.section) THEN RAISE EXCEPTION 'Bạn chưa được duyệt quyền đăng ở khu vực này'; END IF;
  IF NOT public._owns_cat(cat.owner_id, cat.owner_name) THEN
    RAISE EXCEPTION 'Bạn chỉ được đăng link vào nhóm của chính mình'; END IF;

  IF p_id IS NULL THEN
    INSERT INTO public.library_items (name, main, category_id, subcategory, url, creator, tags, description, image_url, owner_id, is_published)
    VALUES (r.name, cat.section, r.category_id, r.subcategory, r.url, r.creator, r.tags, r.description, r.image_url,
            auth.uid(), COALESCE(r.is_published, true))
    RETURNING to_jsonb(library_items.*) INTO res;
  ELSE
    UPDATE public.library_items
    SET name = r.name, main = cat.section, category_id = r.category_id, subcategory = r.subcategory, url = r.url,
        creator = r.creator, tags = r.tags, description = r.description, image_url = r.image_url
    WHERE id::text = p_id AND owner_id = auth.uid()
    RETURNING to_jsonb(library_items.*) INTO res;
    IF res IS NULL THEN RAISE EXCEPTION 'Bạn không sở hữu link này'; END IF;
  END IF;
  RETURN res;
END $$;

-- 8. Chỉ người đã đăng nhập mới gọi được
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.my_cat_add(text,text,text)',
    'public.my_group_rename(text,text,text)',
    'public.my_cat_rename(text,text)',
    'public.my_cat_subs(text,text[])',
    'public.my_cat_delete(text[],boolean)',
    'public.my_item_save(text,jsonb)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM public, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
  END LOOP;
END $$;

-- 9. Cột lời giới thiệu & tùy chỉnh khung giới thiệu trên site_settings
ALTER TABLE public.site_settings ADD COLUMN IF NOT EXISTS intro_text text;
ALTER TABLE public.site_settings ADD COLUMN IF NOT EXISTS intro_style jsonb;
ALTER TABLE public.site_settings ADD COLUMN IF NOT EXISTS hero_width integer;
ALTER TABLE public.site_settings ADD COLUMN IF NOT EXISTS hero_height integer;

NOTIFY pgrst, 'reload schema';
