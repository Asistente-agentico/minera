Traceback (most recent call last):
  File [35m"<string>"[0m, line [35m5[0m, in [35m<module>[0m
    r = c.models.generate_content(model='gemini-2.0-flash', contents='Di hola')
  File [35m"/home/asistente/.local/lib/python3.13/site-packages/google/genai/models.py"[0m, line [35m6405[0m, in [35mgenerate_content[0m
    response = self._generate_content(
        model=model, contents=contents, config=parsed_config
    )
  File [35m"/home/asistente/.local/lib/python3.13/site-packages/google/genai/models.py"[0m, line [35m4841[0m, in [35m_generate_content[0m
    response = self._api_client.request(
        'post', path, request_dict, http_options
    )
  File [35m"/home/asistente/.local/lib/python3.13/site-packages/google/genai/_api_client.py"[0m, line [35m1611[0m, in [35mrequest[0m
    response = self._request(http_request, http_options, stream=False)
  File [35m"/home/asistente/.local/lib/python3.13/site-packages/google/genai/_api_client.py"[0m, line [35m1404[0m, in [35m_request[0m
    return [31mself._retry[0m[1;31m(self._request_once, http_request, stream)[0m  # type: ignore[no-any-return]
           [31m~~~~~~~~~~~[0m[1;31m^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^[0m
  File [35m"/home/asistente/.local/lib/python3.13/site-packages/tenacity/__init__.py"[0m, line [35m470[0m, in [35m__call__[0m
    do = self.iter(retry_state=retry_state)
  File [35m"/home/asistente/.local/lib/python3.13/site-packages/tenacity/__init__.py"[0m, line [35m371[0m, in [35miter[0m
    result = action(retry_state)
  File [35m"/home/asistente/.local/lib/python3.13/site-packages/tenacity/__init__.py"[0m, line [35m413[0m, in [35mexc_check[0m
    raise [31mretry_exc.reraise[0m[1;31m()[0m
          [31m~~~~~~~~~~~~~~~~~[0m[1;31m^^[0m
  File [35m"/home/asistente/.local/lib/python3.13/site-packages/tenacity/__init__.py"[0m, line [35m184[0m, in [35mreraise[0m
    raise [31mself.last_attempt.result[0m[1;31m()[0m
          [31m~~~~~~~~~~~~~~~~~~~~~~~~[0m[1;31m^^[0m
  File [35m"/usr/local/lib/python3.13/concurrent/futures/_base.py"[0m, line [35m449[0m, in [35mresult[0m
    return [31mself.__get_result[0m[1;31m()[0m
           [31m~~~~~~~~~~~~~~~~~[0m[1;31m^^[0m
  File [35m"/usr/local/lib/python3.13/concurrent/futures/_base.py"[0m, line [35m401[0m, in [35m__get_result[0m
    raise self._exception
  File [35m"/home/asistente/.local/lib/python3.13/site-packages/tenacity/__init__.py"[0m, line [35m473[0m, in [35m__call__[0m
    result = fn(*args, **kwargs)
  File [35m"/home/asistente/.local/lib/python3.13/site-packages/google/genai/_api_client.py"[0m, line [35m1381[0m, in [35m_request_once[0m
    [31merrors.APIError.raise_for_response[0m[1;31m(response)[0m
    [31m~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~[0m[1;31m^^^^^^^^^^[0m
  File [35m"/home/asistente/.local/lib/python3.13/site-packages/google/genai/errors.py"[0m, line [35m155[0m, in [35mraise_for_response[0m
    [31mcls.raise_error[0m[1;31m(response.status_code, response_json, response)[0m
    [31m~~~~~~~~~~~~~~~[0m[1;31m^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^[0m
  File [35m"/home/asistente/.local/lib/python3.13/site-packages/google/genai/errors.py"[0m, line [35m184[0m, in [35mraise_error[0m
    raise ClientError(status_code, response_json, response)
[1;35mgoogle.genai.errors.ClientError[0m: [35m404 NOT_FOUND. {'error': {'code': 404, 'message': 'This model models/gemini-2.0-flash is no longer available to new users. Please update your code to use a newer model for the latest features and improvements.', 'status': 'NOT_FOUND'}}[0m
